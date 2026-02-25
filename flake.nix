{
  description = "Personal Nix Configuration";

  inputs = {             
    nixpkgs.url                  = "github:NixOS/nixpkgs/nixos-unstable";
    zen-browser.url              = "github:0xc000022070/zen-browser-flake";
    nix-homebrew.url             = "github:zhaofengli-wip/nix-homebrew";
    sops-nix.url                 = "github:Mic92/sops-nix";
    # nocodb.url                   = "github:nocodb/nocodb";
    _1password-shell-plugins.url = "github:1Password/shell-plugins";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    darwin = {
      url = "github:lnl7/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    secrets = {
      url = "git+ssh://git@github.com/Justin-Arnold/private-config.git";
      flake = true;
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    terranix = {
      url = "github:terranix/terranix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ 
    self,
    nixpkgs,
    nix-darwin,
    home-manager,
    zen-browser,
    nix-homebrew,
    secrets,
    sops-nix,
    # nocodb,
    ...
  } :
  let
    lib = nixpkgs.lib;
    pkgs = nixpkgs.legacyPackages.x86_64-linux;

    mkNixos = hostFile:
      lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs home-manager sops-nix zen-browser; };
        modules = [
          hostFile
          # nocodb.nixosModules.nocodb
        ];
      };

    mkNixos64 = hostFile:
      lib.nixosSystem {
        system = "aarch64-linux";
        specialArgs = { inherit inputs home-manager sops-nix zen-browser; };
        modules = [
          hostFile
        ];
      };
    

    # Like mkNixos but also injects the disko NixOS module, required for
    # hosts whose disk layout is declared in a disk-config.nix (disko file).
    mkNixosDisko = hostFile:
      lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs home-manager sops-nix zen-browser; };
        modules = [
          hostFile
          inputs.disko.nixosModules.disko
        ];
      };

    # Terranix: compile hosts/monitoring-vm/proxmox.nix → config.tf.json
    monitoringVmTerranix = inputs.terranix.lib.terranixConfiguration {
      inherit pkgs;
      modules = [ ./hosts/monitoring-vm/proxmox.nix ];
    };

    mkDarwin = hostFile:
      nix-darwin.lib.darwinSystem {
        system = "aarch64-darwin";
        specialArgs = { inherit home-manager sops-nix zen-browser; };
        modules = [ 
          nix-homebrew.darwinModules.nix-homebrew
          home-manager.darwinModules.home-manager
          hostFile
        ];
      };

  in {
      nixosConfigurations = {
        terraform-controller = mkNixos ./hosts/terraform-controller/configuration.nix;
        ansible-controller   = mkNixos ./hosts/ansible-controller/configuration.nix;
        slim7i               = mkNixos ./hosts/slim7i/configuration.nix;
        desktop              = mkNixos ./hosts/desktop/configuration.nix;
        ollama               = mkNixos ./hosts/ollama/configuration.nix;
        checkmk              = mkNixos ./hosts/checkmk/configuration.nix;
        gitea                = mkNixos ./hosts/gitea/configuration.nix;
        # nocodb               = mkNixos ./hosts/nocodb/configuration.nix;
        onepassword-connect  = mkNixos ./hosts/onepassword-connect/configuration.nix;
        omada-controller     = mkNixos ./hosts/omada-controller/configuration.nix;
        parallels            = mkNixos64 ./hosts/parallels/configuration.nix;
        pangolin-newt        = mkNixos ./hosts/pangolin-newt/configuration.nix;
        pr-previews          = mkNixos ./hosts/pr-previews/configuration.nix;
        github-runner        = mkNixos ./hosts/github-runner/configuration.nix;
        vikunja              = mkNixos ./hosts/vikunja/configuration.nix;
        monitoring-vm        = mkNixosDisko ./hosts/monitoring-vm/configuration.nix;
      };
      darwinConfigurations = {
        macmini              = mkDarwin ./hosts/macmini/configuration.nix;
        macbook16            = mkDarwin ./hosts/macbook16/configuration.nix;
      };

      apps.x86_64-linux = {
        # Compile proxmox.nix → config.tf.json, then terraform init + apply.
        # Run from any directory where you want Terraform state to live:
        #   nix run .#monitoring-vm-apply
        monitoring-vm-apply = {
          type    = "app";
          program = toString (pkgs.writeShellScript "monitoring-vm-apply" ''
            set -euo pipefail
            if [[ -e config.tf.json ]]; then rm -f config.tf.json; fi
            cp ${monitoringVmTerranix} config.tf.json
            ${pkgs.terraform}/bin/terraform init
            ${pkgs.terraform}/bin/terraform apply "$@"
          '');
        };

        # Install NixOS onto the VM via nix-anywhere (idempotent).
        # Provide the target IP as the first argument:
        #   nix run .#monitoring-vm-deploy -- 192.168.1.X
        monitoring-vm-deploy = {
          type    = "app";
          program = toString (pkgs.writeShellScript "monitoring-vm-deploy" ''
            set -euo pipefail
            TARGET_IP=''${1:?Usage: nix run .#monitoring-vm-deploy -- <ip>}
            ${pkgs.nixos-anywhere}/bin/nixos-anywhere \
              --flake .#monitoring-vm \
              root@"$TARGET_IP"
          '');
        };
      };
    };
}
