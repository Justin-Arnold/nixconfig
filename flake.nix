{
  description = "Personal Nix Configuration";

  inputs = {             
    nixpkgs.url                  = "github:NixOS/nixpkgs/nixos-unstable";
    zen-browser.url              = "github:0xc000022070/zen-browser-flake";
    nix-homebrew.url             = "github:zhaofengli-wip/nix-homebrew";
    sops-nix.url                 = "github:Mic92/sops-nix";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    terranix = {
      url = "github:terranix/terranix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-anywhere = {
      url = "github:nix-community/nixos-anywhere";
      inputs.nixpkgs.follows = "nixpkgs";
    };
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
  };

  outputs = inputs@{ 
    self,
    nixpkgs,
    darwin,
    home-manager,
    zen-browser,
    nix-homebrew,
    secrets,
    sops-nix,
    disko,
    terranix,
    nixos-anywhere,
    # nocodb,
    ...
  } :
  let
    lib = nixpkgs.lib;
    terranixHosts = import ./infra/terranix { inherit inputs; };
    supportedSystems = [ "aarch64-darwin" "x86_64-linux" ];

    mkPkgs = system: import nixpkgs {
      inherit system;
      config.allowUnfree = true;
    };

    mkTerranixConfig = system: module:
      terranix.lib.terranixConfiguration {
        inherit system;
        modules = [ module ];
      };

    mkProvisionApp = system: action:
      let
        pkgs = mkPkgs system;
        terranixConfigDockhand = mkTerranixConfig system terranixHosts.dockhand;
        terranixConfigNotifications = mkTerranixConfig system terranixHosts.notifications;
        terranixConfigPrPreviews = mkTerranixConfig system terranixHosts.pr-previews;
        terranixConfigUptimeKuma = mkTerranixConfig system terranixHosts.uptime-kuma;
        provisionApp = pkgs.writeShellApplication {
          name = "nixconfig-${action}";
          runtimeInputs = [
            pkgs.curl
            pkgs.git
            pkgs.jq
            pkgs.nixos-rebuild
            pkgs.openssh
            pkgs.sops
            pkgs.terraform
            nixos-anywhere.packages.${system}.default
          ];
          text = ''
            export NIX_INFRA_ACTION=${action}
            export TERRANIX_CONFIG_DOCKHAND=${terranixConfigDockhand}
            export TERRANIX_CONFIG_NOTIFICATIONS=${terranixConfigNotifications}
            export TERRANIX_CONFIG_PR_PREVIEWS=${terranixConfigPrPreviews}
            export TERRANIX_CONFIG_UPTIME_KUMA=${terranixConfigUptimeKuma}
            exec bash ${./scripts/provisioning/provision-host.sh} "$@"
          '';
        };
      in
      {
        type = "app";
        program = "${provisionApp}/bin/nixconfig-${action}";
      };

    mkNixos = hostFile:
      lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs home-manager sops-nix zen-browser disko; };
        modules = [
          hostFile
          # nocodb.nixosModules.nocodb
        ];
      };

    mkNixos64 = hostFile:
      lib.nixosSystem {
        system = "aarch64-linux";
        specialArgs = { inherit inputs home-manager sops-nix zen-browser disko; };
        modules = [
          hostFile
        ];
      };
    

    mkDarwin = hostFile:
      darwin.lib.darwinSystem {
        system = "aarch64-darwin";
        specialArgs = { inherit inputs home-manager sops-nix zen-browser disko; };
        modules = [ 
          nix-homebrew.darwinModules.nix-homebrew
          home-manager.darwinModules.home-manager
          hostFile
        ];
      };

  in {
      nixosConfigurations = {
        dockhand            = mkNixos ./hosts/dockhand/configuration.nix;
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
        notifications        = mkNixos ./hosts/notifications/configuration.nix;
        uptime-kuma          = mkNixos ./hosts/uptime-kuma/configuration.nix;
      };
      darwinConfigurations = {
        macmini              = mkDarwin ./hosts/macmini/configuration.nix;
        macbook16            = mkDarwin ./hosts/macbook16/configuration.nix;
      };
      terranixConfigurations = lib.genAttrs supportedSystems (system: {
        dockhand = mkTerranixConfig system terranixHosts.dockhand;
        notifications = mkTerranixConfig system terranixHosts.notifications;
        pr-previews = mkTerranixConfig system terranixHosts.pr-previews;
        uptime-kuma = mkTerranixConfig system terranixHosts.uptime-kuma;
      });
      apps = lib.genAttrs supportedSystems (system: {
        plan = mkProvisionApp system "plan";
        provision = mkProvisionApp system "provision";
        install = mkProvisionApp system "install";
        switch = mkProvisionApp system "switch";
        destroy = mkProvisionApp system "destroy";
        adopt = mkProvisionApp system "adopt";
        migrate-state = mkProvisionApp system "migrate-state";
      });
    };
}
