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
    p99 = {
      url = "github:Justin-Arnold/p99";
    };
    codex-desktop-linux.url = "github:ilysenko/codex-desktop-linux";
    codex-cli-nix.url = "github:sadjow/codex-cli-nix/main";
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
    p99,
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

    # Per-host platform, rendered Terraform JSON and deploy target, read by
    # scripts/provisioning/provision-host.sh.
    mkInfraManifest = system:
      (mkPkgs system).writeText "nixconfig-infra-hosts.json" (builtins.toJSON (lib.mapAttrs
        (_: host: {
          inherit (host) platform;
          terraformConfig = "${mkTerranixConfig system host.module}";
          deployTarget = host.deployTarget or null;
        })
        terranixHosts));

    mkProvisionApp = system: action:
      let
        pkgs = mkPkgs system;
        provisionApp = pkgs.writeShellApplication {
          name = "nixconfig-${action}";
          runtimeInputs = [
            pkgs.age
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
            export NIXCONFIG_INFRA_HOSTS=${mkInfraManifest system}
            export NIXCONFIG_PLAN_GUARD=${./scripts/provisioning/plan-guard.jq}
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
        specialArgs = { inherit inputs home-manager sops-nix zen-browser disko p99; };
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
        lab118-services      = mkNixos ./hosts/lab118-services/configuration.nix;
      };
      darwinConfigurations = {
        macmini              = mkDarwin ./hosts/macmini/configuration.nix;
        macbook16            = mkDarwin ./hosts/macbook16/configuration.nix;
      };
      terranixConfigurations = lib.genAttrs supportedSystems (system:
        lib.mapAttrs (_: host: mkTerranixConfig system host.module) terranixHosts);
      checks = lib.genAttrs supportedSystems (system:
        let
          pkgs = mkPkgs system;
          # Evaluates the full host (all assertions) with example facts and no
          # SOPS file, so it runs anywhere.
          lab118Example = self.nixosConfigurations.lab118-services.extendModules {
            modules = [ ./hosts/lab118-services/eval-test.nix ];
          };
        in {
          doppler-secrets = import ./modules/roles/doppler-secrets/check.nix { inherit pkgs lib; };
          provisioning = import ./scripts/provisioning/tests/check.nix {
            inherit pkgs;
            manifest = mkInfraManifest system;
          };
          lab118-services-eval = pkgs.writeText "lab118-services-eval"
            (builtins.unsafeDiscardStringContext lab118Example.config.system.build.toplevel.drvPath);
          # Each case breaks the exposure policy; evaluation must refuse all of them.
          lab118-services-exposure-guards =
            let
              refused = module: !(builtins.tryEval
                (lab118Example.extendModules { modules = [ module ]; }).config.system.build.toplevel.drvPath).success;
              results = lib.mapAttrs (_: refused) {
                container-port-on-all-interfaces = { virtualisation.oci-containers.containers.uptime-kuma.ports = lib.mkForce [ "3001:3001" ]; };
                node-red-published-publicly = { roles.notificationsStack.nodeRed.hostBind = "0.0.0.0"; };
                extra-public-tcp-port = { networking.firewall.allowedTCPPorts = [ 5000 ]; };
                extra-public-udp-port = { networking.firewall.allowedUDPPorts = [ 9999 ]; };
                hawser-agent-enabled = { roles.docker.dockhandManaged.enable = lib.mkForce true; };
                incomplete-facts = { lab118.facts = lib.mkOverride 40 ((import ./hosts/lab118-services/facts.nix) // { diskDevice = null; }); };
              };
            in
            assert lib.assertMsg (lib.all lib.id (lib.attrValues results))
              "exposure guards did not refuse: ${toString (lib.attrNames (lib.filterAttrs (_: ok: !ok) results))}";
            pkgs.writeText "lab118-services-exposure-guards" (builtins.toJSON results);
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
