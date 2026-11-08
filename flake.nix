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
    p99 = {
      url = "github:Justin-Arnold/p99";
    };
    codex-desktop-linux.url = "github:ilysenko/codex-desktop-linux";
    codex-cli-nix.url = "github:sadjow/codex-cli-nix/main";
    # The agents VM's Hermes instances (roles.hermesAgents), pinned to a
    # release. Its own nixpkgs builds it; home-manager is only for its checks.
    hermes-agent = {
      url = "github:NousResearch/hermes-agent/v0.22.5";
      inputs.home-manager.follows = "home-manager";
    };
    nix-openclaw = {
      url = "github:openclaw/nix-openclaw/v2026.10.7";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
  };

  outputs = inputs@{ 
    self,
    nixpkgs,
    darwin,
    home-manager,
    zen-browser,
    nix-homebrew,
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

    # Per-host platform, rendered Terraform JSON, deploy target and whether the
    # host installs with its own age key, read by
    # scripts/provisioning/provision-host.sh.
    mkInfraManifest = system:
      (mkPkgs system).writeText "nixconfig-infra-hosts.json" (builtins.toJSON (lib.mapAttrs
        (_: host: {
          inherit (host) platform;
          terraformConfig = "${mkTerranixConfig system host.module}";
          deployTarget = host.deployTarget or null;
          hostAgeKey = host.hostAgeKey or false;
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
            export NIXCONFIG_PROXMOX_PLAN_GUARD=${./scripts/provisioning/proxmox-plan-guard.jq}
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
        slim7i               = mkNixos ./hosts/slim7i/configuration.nix;
        desktop              = mkNixos ./hosts/desktop/configuration.nix;
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
        dashboard            = mkNixos ./hosts/dashboard/configuration.nix;
        agents               = mkNixos ./hosts/agents/configuration.nix;
        workbench            = mkNixos ./hosts/workbench/configuration.nix;
        openclaw             = mkNixos ./hosts/openclaw/configuration.nix;
        inference            = mkNixos ./hosts/inference/configuration.nix;
        automation           = mkNixos ./hosts/automation/configuration.nix;
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
          # The same for dashboard: no real SOPS file needed.
          dashboardExample = self.nixosConfigurations.dashboard.extendModules {
            modules = [ ./hosts/dashboard/eval-test.nix ];
          };
          # And for agents.
          agentsExample = self.nixosConfigurations.agents.extendModules {
            modules = [ ./hosts/agents/eval-test.nix ];
          };
          # And for workbench, with an example GitHub account and agent key.
          workbenchExample = self.nixosConfigurations.workbench.extendModules {
            modules = [ ./hosts/workbench/eval-test.nix ];
          };
          # And for openclaw, with the Paperclip tools and both chat channels on.
          openclawExample = self.nixosConfigurations.openclaw.extendModules {
            modules = [ ./hosts/openclaw/eval-test.nix ];
          };
          # And for inference.
          inferenceExample = self.nixosConfigurations.inference.extendModules {
            modules = [ ./hosts/inference/eval-test.nix ];
          };
          # And for automation.
          automationExample = self.nixosConfigurations.automation.extendModules {
            modules = [ ./hosts/automation/eval-test.nix ];
          };
        in {
          doppler-secrets = import ./modules/roles/doppler-secrets/check.nix { inherit pkgs lib; };
          sqlite-backup = import ./modules/roles/sqlite-backup/check.nix { inherit pkgs lib; };
          agent-watch = import ./hosts/agents/agent-watch/check.nix { inherit pkgs; };
          agent-costs = import ./hosts/agents/agent-costs/check.nix { inherit pkgs; };
          lab-health = import ./hosts/agents/lab-health/check.nix { inherit pkgs; };
          board-bridge = import ./hosts/agents/board-bridge/check.nix { inherit pkgs; };
          paperclip-events = import ./hosts/agents/paperclip-events/check.nix { inherit pkgs; };
          jev-mcp = import ./modules/roles/hermes-agents/jev-mcp/check.nix { inherit pkgs; };
          paperclip-mcp = import ./modules/roles/hermes-agents/paperclip-mcp/check.nix { inherit pkgs; };
          lab-mcp = import ./modules/roles/hermes-agents/lab-mcp/check.nix { inherit pkgs; };
          notifications-stack = import ./modules/roles/notifications-stack/check.nix { inherit pkgs; };
          provisioning = import ./scripts/provisioning/tests/check.nix {
            inherit pkgs;
            manifest = mkInfraManifest system;
          };
          lab118-services-eval = pkgs.writeText "lab118-services-eval"
            (builtins.unsafeDiscardStringContext lab118Example.config.system.build.toplevel.drvPath);
          dashboard-eval = pkgs.writeText "dashboard-eval"
            (builtins.unsafeDiscardStringContext dashboardExample.config.system.build.toplevel.drvPath);
          agents-eval = pkgs.writeText "agents-eval"
            (builtins.unsafeDiscardStringContext agentsExample.config.system.build.toplevel.drvPath);
          workbench-eval = pkgs.writeText "workbench-eval"
            (builtins.unsafeDiscardStringContext workbenchExample.config.system.build.toplevel.drvPath);
          openclaw-eval = pkgs.writeText "openclaw-eval"
            (builtins.unsafeDiscardStringContext openclawExample.config.system.build.toplevel.drvPath);
          automation-eval = pkgs.writeText "automation-eval"
            (builtins.unsafeDiscardStringContext automationExample.config.system.build.toplevel.drvPath);
          # Once with each model in models.nix as the active one.
          inference-eval = pkgs.writeText "inference-eval" (builtins.toJSON (lib.mapAttrs
            (name: _: builtins.unsafeDiscardStringContext (inferenceExample.extendModules {
              modules = [ { roles.inference.active = lib.mkForce name; } ];
            }).config.system.build.toplevel.drvPath)
            self.nixosConfigurations.inference.config.roles.inference.models));
          # The Hermes agents in Paperclip's spec are the ones on the agents host, at their ports, and
          # every routine has an agent from the spec and its description file.
          paperclip-spec =
            let
              spec = lib.importJSON ./scripts/agents/paperclip-spec.json;
              agentsConfig = self.nixosConfigurations.agents.config;
              onHost = lib.mapAttrs (_: agent: "http://127.0.0.1:${toString agent.port}")
                agentsConfig.roles.hermesAgents.instances;
              inSpec = lib.listToAttrs (map (agent: lib.nameValuePair (lib.toLower agent.name) agent.adapterConfig.apiBaseUrl)
                (lib.filter (agent: agent.adapterType == "hermes_gateway") spec.agents));
              names = map (agent: agent.name) spec.agents;
              badRoutines = lib.filter (routine: !(lib.elem routine.assignee names)
                || !(builtins.pathExists (./scripts/agents + "/${routine.descriptionFile}"))) (spec.routines or [ ]);
              watch = agentsConfig.agents.watch;
              triage = lib.findFirst (routine: routine.title == watch.intake.routineTitle) null (spec.routines or [ ]);
              health = agentsConfig.agents.labHealth;
              findings = lib.findFirst (routine: routine.title == health.routineTitle) null (spec.routines or [ ]);
            in
            assert lib.assertMsg (onHost == inSpec)
              "scripts/agents/paperclip-spec.json doesn't match hosts/agents/agents.nix: ${builtins.toJSON { inherit onHost inSpec; }}";
            assert lib.assertMsg (badRoutines == [ ])
              "scripts/agents/paperclip-spec.json: these routines name an agent or a description file that doesn't exist: ${builtins.toJSON (map (r: r.title) badRoutines)}";
            # n8n starts the triage through this routine's webhook and waits while one of its issues is open;
            # agent-watch finds it by its title.
            assert lib.assertMsg (!(watch.enable && watch.intake.enable) || (triage != null && triage.assignee == "Monitor"
              && lib.any (trigger: trigger.kind == "webhook" && (trigger.watchOpen or false)) (triage.triggers or [ ])))
              "scripts/agents/paperclip-spec.json has no routine for the monitor titled ${builtins.toJSON watch.intake.routineTitle} with a webhook trigger that has watchOpen (agents.watch.intake.routineTitle)";
            # lab-health runs this routine by its title with the monitor's key, which runs only the monitor's own.
            assert lib.assertMsg (!health.active || (findings != null && findings.assignee == "Monitor"))
              "scripts/agents/paperclip-spec.json has no routine for the monitor titled ${builtins.toJSON health.routineTitle} (agents.labHealth.routineTitle)";
            pkgs.writeText "paperclip-spec" (builtins.toJSON inSpec);
          # Each case breaks the dashboard's exposure policy; evaluation must refuse all of them.
          dashboard-exposure-guards =
            let
              refused = module: !(builtins.tryEval
                (dashboardExample.extendModules { modules = [ module ]; }).config.system.build.toplevel.drvPath).success;
              lanVhost = "dashboard.servicestack.xyz";
              results = lib.mapAttrs (_: refused) {
                homarr-on-all-interfaces = { roles.homarr.hostBind = lib.mkForce "0.0.0.0"; };
                extra-public-tcp-port = { networking.firewall.allowedTCPPorts = [ 7575 ]; };
                extra-public-udp-port = { networking.firewall.allowedUDPPorts = [ 9999 ]; };
                interface-opening = { networking.firewall.interfaces.docker0.allowedTCPPorts = [ 8090 ]; };
                trusted-interface = { networking.firewall.trustedInterfaces = [ "docker0" ]; };
                hub-listens-publicly = { services.beszel.hub.host = lib.mkForce "0.0.0.0"; };
                mcp-unguarded-in-lan = { services.nginx.virtualHosts.${lanVhost}.extraConfig = lib.mkForce ""; };
                pangolin-reaches-hub-admin = { services.nginx.virtualHosts."beszel.servicestack.xyz".locations."^~ /_/".extraConfig = lib.mkForce "allow 10.0.0.0/24;\ndeny all;\n"; };
                pangolin-reaches-agent-endpoint = { services.nginx.virtualHosts."beszel.servicestack.xyz".locations."= /api/beszel/agent-connect".extraConfig = lib.mkForce "allow 10.0.0.0/24;\ndeny all;\n"; };
                location-shadows-guard = { services.nginx.virtualHosts.${lanVhost}.locations."^~ /api/".proxyPass = "http://127.0.0.1:7575"; };
                docker-socket-in-homarr = { virtualisation.oci-containers.containers.homarr.volumes = [ "/var/run/docker.sock:/var/run/docker.sock" ]; };
                docker-api-enabled = { roles.homarr.environment.ENABLE_DOCKER = "true"; };
                key-in-environment = { roles.homarr.environment.SECRET_ENCRYPTION_KEY = "0000000000000000000000000000000000000000000000000000000000000000"; };
                hawser-agent-enabled = { roles.docker.dockhandManaged.enable = lib.mkForce true; };
                sops-file-missing = { sops.validateSopsFiles = lib.mkOverride 40 true; };
                backup-target-missing = { dashboard.backup.nfsDevice = lib.mkOverride 40 null; };
                beszel-agent-listening = { services.beszel.agent.openFirewall = true; };
              };
            in
            assert lib.assertMsg (lib.all lib.id (lib.attrValues results))
              "dashboard exposure guards did not refuse: ${toString (lib.attrNames (lib.filterAttrs (_: ok: !ok) results))}";
            pkgs.writeText "dashboard-exposure-guards" (builtins.toJSON results);
          # Each case breaks the agents host's exposure policy; evaluation must refuse all of them.
          agents-exposure-guards =
            let
              refused = module: !(builtins.tryEval
                (agentsExample.extendModules { modules = [ module ]; }).config.system.build.toplevel.drvPath).success;
              vhost = "paperclip.servicestack.xyz";
              triggers = "paperclip-triggers.servicestack.xyz";
              fire = ''~ "^/api/routine-triggers/public/(?<trigger>[0-9a-f]{24})/fire$"'';
              results = lib.mapAttrs (_: refused) {
                triggers-from-lan = { services.nginx.virtualHosts.${triggers}.locations.${fire}.extraConfig = lib.mkForce "allow 10.0.0.0/24;\ndeny all;\nlimit_except POST { deny all; }\n"; };
                triggers-any-method = { services.nginx.virtualHosts.${triggers}.locations.${fire}.extraConfig = lib.mkForce "allow 10.0.0.155;\ndeny all;\n"; };
                triggers-extra-location = { services.nginx.virtualHosts.${triggers}.locations."/api/".proxyPass = "http://127.0.0.1:3100"; };
                triggers-root-proxied = { services.nginx.virtualHosts.${triggers}.locations."/" = { return = lib.mkForce null; proxyPass = "http://127.0.0.1:3100"; }; };
                triggers-passes-query = { services.nginx.virtualHosts.${triggers}.locations.${fire}.proxyPass = lib.mkForce "http://127.0.0.1:3100"; };
                unguarded-with-variable = { services.nginx.virtualHosts."other.servicestack.xyz".locations."/".proxyPass = "http://127.0.0.1:3100$uri"; };
                extra-public-tcp-port = { networking.firewall.allowedTCPPorts = [ 3100 ]; };
                extra-public-udp-port = { networking.firewall.allowedUDPPorts = [ 9999 ]; };
                interface-opening = { networking.firewall.interfaces.podman0.allowedTCPPorts = [ 3100 ]; };
                trusted-interface = { networking.firewall.trustedInterfaces = [ "podman0" ]; };
                docker-enabled = { virtualisation.docker.enable = true; };
                paperclip-published = { virtualisation.oci-containers.containers.paperclip.ports = [ "3100:3100" ]; };
                paperclip-on-all-interfaces = { virtualisation.oci-containers.containers.paperclip.environment.HOST = lib.mkForce "0.0.0.0"; };
                paperclip-bridged = { virtualisation.oci-containers.containers.paperclip.extraOptions = lib.mkForce [ ]; };
                socket-in-paperclip = { virtualisation.oci-containers.containers.paperclip.volumes = [ "/run/podman/podman.sock:/run/podman/podman.sock" ]; };
                local-trusted = { virtualisation.oci-containers.containers.paperclip.environment.PAPERCLIP_DEPLOYMENT_MODE = lib.mkForce "local_trusted"; };
                public-exposure = { virtualisation.oci-containers.containers.paperclip.environment.PAPERCLIP_DEPLOYMENT_EXPOSURE = lib.mkForce "public"; };
                telemetry-on = { virtualisation.oci-containers.containers.paperclip.environment.PAPERCLIP_TELEMETRY_DISABLED = lib.mkForce "0"; };
                secret-in-environment = { roles.paperclip.environment.BETTER_AUTH_SECRET = "0000"; };
                plain-http-public-url = { roles.paperclip.publicUrl = lib.mkForce "http://paperclip.servicestack.xyz"; };
                postgres-on-network = { services.postgresql.enableTCPIP = lib.mkForce true; };
                guard-missing = { services.nginx.virtualHosts.${vhost}.extraConfig = lib.mkForce ""; };
                location-shadows-guard = { services.nginx.virtualHosts.${vhost}.locations."^~ /mcp".proxyPass = "http://127.0.0.1:3100"; };
                sops-file-missing = { sops.validateSopsFiles = lib.mkOverride 40 true; };
                backup-target-missing = { agents.backup.nfsDevice = lib.mkOverride 40 null; };
                beszel-agent-listening = { services.beszel.agent.openFirewall = true; };
                bridge-reaches-lan = { systemd.services.board-bridge.serviceConfig.IPAddressDeny = lib.mkForce [ "10.0.0.0/8" ]; };
                bridge-allows-lan = { systemd.services.board-bridge.serviceConfig.IPAddressAllow = lib.mkForce [ "localhost" "10.0.0.0/24" ]; };
                events-allows-lan = { systemd.services.paperclip-events.serviceConfig.IPAddressAllow = lib.mkForce [ "localhost" "10.0.0.0/24" ]; };
                events-reaches-internet = { systemd.services.paperclip-events.serviceConfig.IPAddressDeny = lib.mkForce [ "10.0.0.0/8" ]; };
                lab-health-allows-lan = { systemd.services.lab-health.serviceConfig.IPAddressAllow = lib.mkForce [ "localhost" "10.0.0.0/24" ]; };
                lab-health-reaches-internet = { systemd.services.lab-health.serviceConfig.IPAddressDeny = lib.mkForce [ "10.0.0.0/8" ]; };
                lab-health-dry-run-allows-lan = { systemd.services.lab-health-dry-run.serviceConfig.IPAddressAllow = lib.mkForce [ "localhost" "10.0.0.0/24" ]; };
                hermes-api-on-all-interfaces = { roles.hermesAgents.instances.coordinator.environment.API_SERVER_HOST = lib.mkForce "0.0.0.0"; };
                hermes-duplicate-port = { roles.hermesAgents.instances.engineer.port = lib.mkForce 8642; };
                hermes-machine-tools-here = { roles.hermesAgents.instances.coordinator.toolsets = [ "terminal" ]; };
                hermes-backend-override = { roles.hermesAgents.instances.engineer.settings.terminal.backend = "docker"; };
                hermes-credentials-to-terminal = { roles.hermesAgents.instances.engineer.settings.terminal.credential_files = [ "auth.json" ]; };
                hermes-browser = { roles.hermesAgents.instances.researcher.toolsets = [ "browser" ]; };
                hermes-approvals-off = { roles.hermesAgents.instances.engineer.settings.approvals.mode = "off"; };
                hermes-deny-list-dropped = { roles.hermesAgents.instances.engineer.settings.approvals.deny = [ ]; };
                hermes-yolo = { roles.hermesAgents.instances.engineer.extraArgs = [ "--yolo" ]; };
                hermes-messaging = { roles.hermesAgents.instances.coordinator.secrets.TELEGRAM_BOT_TOKEN = "hermes/coordinator/telegram"; };
                hermes-extra-mcp = { roles.hermesAgents.instances.coordinator.mcpServers.shell.command = "/bin/sh"; };
                hermes-mcp-inline-key = { roles.hermesAgents.instances.coordinator.mcpServers.paperclip = { command = "x"; env.PAPERCLIP_API_KEY = "plaintext"; }; };
                hermes-project-skills = { roles.hermesAgents.instances.coordinator.settings.skills.project_discovery = true; };
                egress-off = { roles.agentEgress.enable = lib.mkForce false; };
                egress-misses-agent = { roles.agentEgress.users = lib.mkForce [ "hermes-coordinator" "hermes-engineer" ]; };
                egress-allows-range = { roles.agentEgress.allow.lan = { address = "10.0.0.0/24"; tcpPorts = [ 22 ]; }; };
                egress-allows-whole-host = { roles.agentEgress.allow.nas.address = "10.0.0.20"; };
                egress-allows-unknown-user = { roles.agentEgress.allow.inference = lib.mkForce { address = "10.0.0.63"; tcpPorts = [ 443 ]; users = [ "justin" ]; }; };
                provider-plain-http = { roles.hermesAgents.providers.lab-gpu.baseUrl = lib.mkForce "http://10.0.0.63:8080/v1"; };
                provider-reserved-name = { roles.hermesAgents.providers.local = { baseUrl = "https://inference.servicestack.xyz/v1"; keyEnv = "LOCAL_KEY"; keySecret = "inference/agents-key"; models.local.contextLength = 65536; }; };
                provider-short-context = { roles.hermesAgents.providers.lab-gpu.models.local.contextLength = lib.mkForce 32768; };
                provider-inline-key = { roles.hermesAgents.instances.coordinator.settings.providers.lab-gpu.api_key = "a-literal-key"; };
                provider-key-command = { roles.hermesAgents.instances.coordinator.settings.providers.lab-gpu.key_cmd = "cat /run/secrets/x"; };
                provider-added-plain-http = { roles.hermesAgents.instances.coordinator.settings.providers.other = { base_url = "http://10.0.0.63:8080/v1"; key_env = "LAB_INFERENCE_KEY"; }; };
                side-task-inline-key = { roles.hermesAgents.instances.engineer.settings.auxiliary.title_generation.api_key = "a-literal-key"; };
                side-task-own-endpoint = { roles.hermesAgents.instances.engineer.settings.auxiliary.background_review.base_url = "http://10.0.0.63:8080/v1"; };
                fallback-inline-key = { roles.hermesAgents.instances.researcher.settings.fallback_providers = [ { provider = "lab-gpu"; model = "local"; api_key = "a-literal-key"; } ]; };
                provider-key-not-from-sops = { roles.hermesAgents.instances.coordinator.secrets.LAB_INFERENCE_KEY = lib.mkForce "hermes/coordinator/paperclip-key"; };
                provider-unlisted-model = { roles.hermesAgents.instances.researcher.model = lib.mkForce { provider = "lab-gpu"; name = "qwen3.6-35b-a3b"; }; };
                compression-local = { roles.hermesAgents.instances.coordinator.auxiliary.compression = { provider = "lab-gpu"; name = "local"; }; };
                compression-follows-local-model = { roles.hermesAgents.instances.researcher.auxiliary = lib.mkForce { }; };
                claude-key-on-researcher = { roles.hermesAgents.instances.researcher.secrets.ANTHROPIC_API_KEY = "anthropic/api-key"; };
                claude-oauth-token = { roles.hermesAgents.instances.coordinator.secrets.CLAUDE_CODE_OAUTH_TOKEN = "anthropic/api-key"; };
                claude-token-in-environment = { roles.hermesAgents.instances.engineer.environment.ANTHROPIC_TOKEN = "x"; };
                claude-other-endpoint = { roles.hermesAgents.instances.coordinator.environment.ANTHROPIC_BASE_URL = "https://proxy.example.com"; };
                claude-through-settings = { roles.hermesAgents.instances.researcher.settings.fallback_providers = [ { provider = "anthropic"; model = "claude-opus-5-5"; } ]; };
                claude-model-not-listed = { roles.hermesAgents.instances.coordinator.fallbacks = lib.mkForce [ { provider = "anthropic"; name = "claude-fable-5-1"; } ]; };
                claude-without-key = { roles.hermesAgents.anthropic.keySecret = lib.mkForce null; };
                jev-key-names-anthropic = { roles.hermesAgents.instances.coordinator.mcpServers.jev.env.JEV_API_KEY = lib.mkForce "\${ANTHROPIC_API_KEY}"; };
                jev-inline-key = { roles.hermesAgents.instances.coordinator.mcpServers.jev.env.JEV_API_KEY = lib.mkForce "a-literal-key"; };
                paperclip-takes-other-key = { roles.hermesAgents.instances.coordinator.mcpServers.paperclip.env.X = "\${LAB_INFERENCE_KEY}"; };
                jev-args-take-key = { roles.hermesAgents.instances.engineer.mcpServers.jev.args = [ "\${env:PAPERCLIP_AGENT_KEY}" ]; };
                jev-runs-shell = { roles.hermesAgents.instances.engineer.mcpServers.jev.command = lib.mkForce "/bin/sh"; };
                jev-remote = { roles.hermesAgents.instances.researcher.mcpServers.jev.url = "https://jev.example.com/mcp"; };
                mcp-sampling-on = { roles.hermesAgents.instances.coordinator.mcpServers.paperclip.sampling.enabled = lib.mkForce true; };
                jev-plain-http = { roles.hermesAgents.jev.baseUrl = lib.mkForce "http://10.0.0.63:8080/v1"; };
                jev-key-not-from-sops = { roles.hermesAgents.instances.researcher.secrets.JEV_API_KEY = lib.mkForce "hermes/researcher/paperclip-key"; };
                jev-key-without-tool = { roles.hermesAgents.instances.researcher = { jev.enable = lib.mkForce false; secrets.JEV_API_KEY = "jev/api-key"; }; };
                reviewer-may-push = { roles.hermesAgents.instances.reviewer.extraDenyCommands = lib.mkForce [ ]; };
                # The engineer has no extras, so its list is exactly every agent's.
                # settings merges with recursiveUpdate, so this list replaces the
                # reviewer's (and mkForce would land in it as a value).
                reviewer-extras-dropped = { roles.hermesAgents.instances.reviewer.settings.approvals.deny = agentsExample.config.roles.hermesAgents.instances.engineer.settings.approvals.deny; };
                claude-key-not-from-sops-on-reviewer = { roles.hermesAgents.instances.reviewer.secrets.ANTHROPIC_API_KEY = lib.mkForce "jev/api-key"; };
                lab-takes-other-key = { roles.hermesAgents.instances.researcher.mcpServers.lab.env.X = "\${PAPERCLIP_AGENT_KEY}"; };
                lab-key-without-tools = { roles.hermesAgents.instances.engineer.secrets.LAB_PROXMOX_TOKEN = "observe/proxmox-token"; };
                lab-key-not-from-sops = { roles.hermesAgents.instances.infra.secrets.LAB_ALERTA_KEY = lib.mkForce "agent-watch/alerta-key"; };
                lab-plain-http-proxmox = { roles.hermesAgents.observe.proxmox = lib.mkOverride 40 { urls = [ "http://10.0.0.14:8006" ]; caFile = ./flake.nix; }; };
                lab-plain-http-off-tunnel = { roles.hermesAgents.observe.kuma = lib.mkOverride 40 { url = "http://10.0.0.5:3002"; slug = "agents"; }; };
                egress-to-node-red = { roles.agentEgress.allow.lab118.tcpPorts = lib.mkForce [ 3002 5000 1880 ]; };
                github-writable = { roles.hermesAgents.instances.researcher.mcpServers.github.args = [ "--read-only=false" ]; };
                github-token-not-from-sops = { roles.hermesAgents.instances.coordinator.secrets.GITHUB_OBSERVE_TOKEN = lib.mkForce "jev/api-key"; };
                github-through-settings = { roles.hermesAgents.instances.engineer.settings.mcp_servers.github.command = "github-mcp-server"; };
              };
            in
            assert lib.assertMsg (lib.all lib.id (lib.attrValues results))
              "agents exposure guards did not refuse: ${toString (lib.attrNames (lib.filterAttrs (_: ok: !ok) results))}";
            pkgs.writeText "agents-exposure-guards" (builtins.toJSON results);
          # Each case breaks workbench's exposure policy; evaluation must refuse all of them.
          workbench-exposure-guards =
            let
              refused = module: !(builtins.tryEval
                (workbenchExample.extendModules { modules = [ module ]; }).config.system.build.toplevel.drvPath).success;
              results = lib.mapAttrs (_: refused) {
                extra-public-tcp-port = { networking.firewall.allowedTCPPorts = [ 8080 ]; };
                extra-public-udp-port = { networking.firewall.allowedUDPPorts = [ 9999 ]; };
                interface-opening = { networking.firewall.interfaces.podman0.allowedTCPPorts = [ 8080 ]; };
                trusted-interface = { networking.firewall.trustedInterfaces = [ "podman0" ]; };
                docker-enabled = { virtualisation.docker.enable = true; };
                docker-socket = { virtualisation.podman.dockerSocket.enable = true; };
                agent-in-wheel = { users.users.agent-engineer.extraGroups = [ "wheel" ]; };
                agent-sudo-rule = { security.sudo.extraRules = [ { users = [ "agent-engineer" ]; commands = [ "ALL" ]; } ]; };
                agent-nix-trusted = { nix.settings.trusted-users = [ "agent-engineer" ]; };
                everyone-nix-trusted = { nix.settings.trusted-users = [ "*" ]; };
                nix-sandbox-off = { nix.settings.sandbox = lib.mkForce false; };
                egress-off = { roles.agentEgress.enable = lib.mkForce false; };
                egress-misses-agent = { users.users.agent-stray = { isNormalUser = true; uid = 3399; }; };
                egress-misses-builds = { roles.agentEgress.groups = lib.mkForce [ ]; };
                key-from-anywhere = { users.users.agent-engineer.openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILoose loose" ]; };
                key-with-forwarding = { users.users.agent-engineer.openssh.authorizedKeys.keys = [ ''restrict,port-forwarding,from="10.0.0.152" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILoose loose'' ]; };
                sops-file-missing = { sops.validateSopsFiles = lib.mkOverride 40 true; };
                beszel-agent-listening = { services.beszel.agent.openFirewall = true; };
              };
            in
            assert lib.assertMsg (lib.all lib.id (lib.attrValues results))
              "workbench exposure guards did not refuse: ${toString (lib.attrNames (lib.filterAttrs (_: ok: !ok) results))}";
            pkgs.writeText "workbench-exposure-guards" (builtins.toJSON results);
          # Each case breaks openclaw's exposure policy; evaluation must refuse all of them.
          openclaw-exposure-guards =
            let
              refused = module: !(builtins.tryEval
                (openclawExample.extendModules { modules = [ module ]; }).config.system.build.toplevel.drvPath).success;
              oc = settings: { roles.openclaw.settings = settings; };
              vhost = "openclaw.servicestack.xyz";
              results = lib.mapAttrs (_: refused) {
                extra-public-tcp-port = { networking.firewall.allowedTCPPorts = [ 18789 ]; };
                extra-public-udp-port = { networking.firewall.allowedUDPPorts = [ 5353 ]; };
                interface-opening = { networking.firewall.interfaces.ens18.allowedTCPPorts = [ 18789 ]; };
                trusted-interface = { networking.firewall.trustedInterfaces = [ "ens18" ]; };
                docker-enabled = { virtualisation.docker.enable = true; };
                podman-enabled = { virtualisation.podman.enable = true; };
                gateway-on-lan = oc { gateway.bind = lib.mkForce "lan"; };
                gateway-auth-off = oc { gateway.auth.mode = lib.mkForce "none"; };
                gateway-token-literal = oc { gateway.auth.token = lib.mkForce "a-literal-token-that-lands-in-the-store"; };
                gateway-tailscale-auth = oc { gateway.auth.allowTailscale = lib.mkForce true; };
                proxy-trusts-lan = oc { gateway.trustedProxies = lib.mkForce [ "10.0.0.0/24" ]; };
                terminal-on = oc { gateway.terminal.enabled = lib.mkForce true; };
                dangerously-flag = oc { gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback = true; };
                tools-full-profile = oc { tools.profile = lib.mkForce "full"; };
                tools-extra-allow = oc { tools.alsoAllow = lib.mkForce [ "bundle-mcp" "web_fetch" ]; };
                tools-shell-undenied = oc { tools.deny = lib.mkForce [ "gateway" "browser" ]; };
                exec-full = oc { tools.exec.mode = lib.mkForce "full"; };
                elevated-on = oc { tools.elevated.enabled = lib.mkForce true; };
                browser-on = oc { browser.enabled = lib.mkForce true; };
                web-fetch-on = oc { tools.web.fetch.enabled = lib.mkForce true; };
                skill-installs = oc { security.installPolicy.enabled = lib.mkForce false; };
                bundled-skills = oc { skills.allowBundled = lib.mkForce [ "github" ]; };
                skill-dirs = oc { skills.load.extraDirs = [ "/var/lib/openclaw/skills" ]; };
                hooks-on = oc { hooks.enabled = lib.mkForce true; };
                second-mcp-server = oc { mcp.servers.shell.command = "/bin/sh"; };
                discord-open-dms = oc { channels.discord = { dmPolicy = lib.mkForce "open"; allowFrom = lib.mkForce [ "*" ]; }; };
                discord-groups = oc { channels.discord.groupPolicy = lib.mkForce "allowlist"; };
                telegram-pairing = oc { channels.telegram.dmPolicy = lib.mkForce "pairing"; };
                egress-off = { roles.agentEgress.enable = lib.mkForce false; };
                extra-vhost = { services.nginx.virtualHosts."other.servicestack.xyz".locations."/".proxyPass = "http://127.0.0.1:18789"; };
                extra-location = { services.nginx.virtualHosts.${vhost}.locations."/api".proxyPass = "http://127.0.0.1:18789"; };
                location-open-to-all = { services.nginx.virtualHosts.${vhost}.locations."/".extraConfig = lib.mkForce "proxy_set_header X-Forwarded-For $remote_addr;"; };
                forwarded-chain = { services.nginx.virtualHosts.${vhost}.locations."/".extraConfig = lib.mkForce "deny all;\nproxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;"; };
                backup-unset = { openclaw.backup.nfsDevice = lib.mkForce null; };
                sops-file-missing = { sops.validateSopsFiles = lib.mkOverride 40 true; };
                beszel-agent-listening = { services.beszel.agent.openFirewall = true; };
              };
            in
            assert lib.assertMsg (lib.all lib.id (lib.attrValues results))
              "openclaw exposure guards did not refuse: ${toString (lib.attrNames (lib.filterAttrs (_: ok: !ok) results))}";
            pkgs.writeText "openclaw-exposure-guards" (builtins.toJSON results);
          # Each case breaks the inference host's exposure policy; evaluation must refuse all of them.
          inference-exposure-guards =
            let
              refused = module: !(builtins.tryEval
                (inferenceExample.extendModules { modules = [ module ]; }).config.system.build.toplevel.drvPath).success;
              vhost = "inference.servicestack.xyz";
              loc = path: extraConfig: { services.nginx.virtualHosts.${vhost}.locations.${path}.extraConfig = lib.mkForce extraConfig; };
              model = files: { roles.inference = { models.unpinned = { inherit files; }; active = lib.mkForce "unpinned"; }; };
              gptOss = lib.head self.nixosConfigurations.inference.config.roles.inference.models.gpt-oss-20b.files;
            in
            let results = lib.mapAttrs (_: refused) {
                extra-public-tcp-port = { networking.firewall.allowedTCPPorts = [ 8080 ]; };
                http-port = { networking.firewall.allowedTCPPorts = [ 80 ]; };
                extra-public-udp-port = { networking.firewall.allowedUDPPorts = [ 5353 ]; };
                interface-opening = { networking.firewall.interfaces.ens18.allowedTCPPorts = [ 8080 ]; };
                trusted-interface = { networking.firewall.trustedInterfaces = [ "ens18" ]; };
                docker-enabled = { virtualisation.docker.enable = true; };
                ollama-enabled = { services.ollama.enable = true; };
                swap-added = { swapDevices = [ { device = "/swapfile"; size = 1024; } ]; };
                zram-added = { zramSwap.enable = true; };
                coredumps-stored = { systemd.coredump.settings.Coredump.Storage = lib.mkForce "external"; };
                short-context = { roles.inference.contextPerSlot = lib.mkForce 32768; };
                one-slot = { roles.inference.parallel = lib.mkForce 1; };
                verbose-logging = { roles.inference.extraFlags = [ "--verbose" ]; };
                prompt-logging = { roles.inference.extraFlags = [ "--verbose-prompt" ]; };
                slots-endpoint = { roles.inference.extraFlags = [ "--slots" ]; };
                props-endpoint = { roles.inference.extraFlags = [ "--props" ]; };
                slot-files = { roles.inference.extraFlags = [ "--slot-save-path" "/var/lib/inference/slots" ]; };
                web-ui = { roles.inference.extraFlags = [ "--ui" ]; };
                server-on-lan = { roles.inference.extraFlags = [ "--host" "0.0.0.0" ]; };
                unified-kv = { roles.inference.extraFlags = [ "--kv-unified" ]; };
                model-from-main = model [ (gptOss // { url = "https://huggingface.co/ggml-org/gpt-oss-20b-GGUF/resolve/main/gpt-oss-20b-mxfp4.gguf"; }) ];
                model-without-hash = model [ (gptOss // { sha256 = ""; }) ];
                model-off-huggingface = model [ (gptOss // { url = "https://example.com/gpt-oss-20b-mxfp4.gguf"; }) ];
                active-model-missing = { roles.inference.active = lib.mkForce "nonexistent"; };
                inactive-model-logs-prompts = { roles.inference.models.spare = { files = [ gptOss ]; extraFlags = [ "--verbose-prompt" ]; }; };
                extra-vhost = { services.nginx.virtualHosts."other.servicestack.xyz".locations."/".proxyPass = "http://127.0.0.1:8080"; };
                extra-location = { services.nginx.virtualHosts.${vhost}.locations."/completion".proxyPass = "http://127.0.0.1:8080"; };
                catch-all-proxied = { services.nginx.virtualHosts.${vhost}.locations."/".proxyPass = "http://127.0.0.1:8080"; };
                catch-all-serves-files = { services.nginx.virtualHosts.${vhost}.locations."/".root = "/var/lib/inference"; };
                props-location = { services.nginx.virtualHosts.${vhost}.locations."= /props".proxyPass = "http://127.0.0.1:8080"; };
                location-open-to-all = loc "= /v1/models" ''proxy_set_header Authorization "";'';
                newt-allowed = loc "= /health" ''allow 10.0.0.0/24; deny all; proxy_set_header Authorization "";'';
                key-passed-on = loc "= /health" "deny 10.0.0.72; allow 10.0.0.0/24; deny all;";
                no-key-check = loc "= /v1/chat/completions" ''deny 10.0.0.72; allow 10.0.0.0/24; deny all; proxy_set_header Authorization "";'';
                bodies-to-disk = { services.nginx.virtualHosts.${vhost}.extraConfig = lib.mkForce "client_max_body_size 8m;"; };
                http-also = { services.nginx.virtualHosts.${vhost}.addSSL = true; };
                key-in-store = { services.nginx.appendHttpConfig = ''map $http_authorization $x { "Bearer 0123456789abcdef" agents; }''; };
                sops-file-missing = { sops.validateSopsFiles = lib.mkOverride 40 true; };
                beszel-agent-listening = { services.beszel.agent.openFirewall = true; };
              };
            in
            assert lib.assertMsg (lib.all lib.id (lib.attrValues results))
              "inference exposure guards did not refuse: ${toString (lib.attrNames (lib.filterAttrs (_: ok: !ok) results))}";
            pkgs.writeText "inference-exposure-guards" (builtins.toJSON results);
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
                beszel-agent-listening = { services.beszel.agent.openFirewall = true; };
                incomplete-facts = { lab118.facts = lib.mkOverride 40 ((import ./hosts/lab118-services/facts.nix) // { diskDevice = null; }); };
                github-intake-any-method = { services.nginx.virtualHosts."intake.lab118.xyz".locations."= /github".extraConfig = lib.mkForce "proxy_pass https://$automation/webhook/github;\nproxy_ssl_verify on;\n"; };
                github-intake-unverified = { services.nginx.virtualHosts."intake.lab118.xyz".locations."= /github".extraConfig = lib.mkForce "limit_except POST { deny all; }\nproxy_pass https://$automation/webhook/github;\nproxy_ssl_verify off;\n"; };
              };
            in
            assert lib.assertMsg (lib.all lib.id (lib.attrValues results))
              "exposure guards did not refuse: ${toString (lib.attrNames (lib.filterAttrs (_: ok: !ok) results))}";
            pkgs.writeText "lab118-services-exposure-guards" (builtins.toJSON results);
          # Each case breaks the automation host's exposure policy; evaluation must refuse all of them.
          automation-exposure-guards =
            let
              refused = module: !(builtins.tryEval
                (automationExample.extendModules { modules = [ module ]; }).config.system.build.toplevel.drvPath).success;
              vhost = "automation.servicestack.xyz";
              results = lib.mapAttrs (_: refused) {
                extra-public-tcp-port = { networking.firewall.allowedTCPPorts = [ 5678 ]; };
                extra-public-udp-port = { networking.firewall.allowedUDPPorts = [ 9999 ]; };
                interface-opening = { networking.firewall.interfaces.ens18.allowedTCPPorts = [ 5678 ]; };
                trusted-interface = { networking.firewall.trustedInterfaces = [ "ens18" ]; };
                n8n-open-firewall = { services.n8n.openFirewall = true; };
                n8n-on-all-interfaces = { services.n8n.environment.N8N_LISTEN_ADDRESS = lib.mkForce "0.0.0.0"; };
                n8n-reaches-lan = { systemd.services.n8n.serviceConfig.IPAddressAllow = lib.mkForce [ "localhost" "10.0.0.0/24" ]; };
                n8n-lan-not-denied = { systemd.services.n8n.serviceConfig.IPAddressDeny = lib.mkForce [ "192.168.0.0/16" ]; };
                n8n-runs-commands = { services.n8n.environment.NODES_EXCLUDE = lib.mkForce "[]"; };
                n8n-runs-code = { services.n8n.environment.NODES_EXCLUDE = lib.mkForce (builtins.toJSON [ "n8n-nodes-base.executeCommand" "n8n-nodes-base.localFileTrigger" ]); };
                n8n-reads-environment = { services.n8n.environment.N8N_BLOCK_ENV_ACCESS_IN_NODE = lib.mkForce false; };
                n8n-community-packages = { services.n8n.environment.N8N_COMMUNITY_PACKAGES_ENABLED = lib.mkForce true; };
                key-in-environment = { services.n8n.environment.N8N_ENCRYPTION_KEY = "0000"; };
                tunnel-reaches-ui = { services.nginx.virtualHosts.${vhost}.locations."/".extraConfig = lib.mkForce "allow 10.118.0.1;\ndeny all;\n"; };
                tunnel-reaches-other-webhook = { services.nginx.virtualHosts.${vhost}.locations."^~ /webhook/".extraConfig = "allow 10.118.0.1;\ndeny all;\n"; };
                lan-reaches-github-webhook = { services.nginx.virtualHosts.${vhost}.locations."= /webhook/github".extraConfig = lib.mkForce "allow 10.0.0.0/24;\nallow 10.118.0.1;\ndeny all;\n"; };
                lan-reaches-alerta-webhook = { services.nginx.virtualHosts.${vhost}.locations."= /webhook/alerta".extraConfig = lib.mkForce "allow 10.0.0.0/24;\nallow 10.118.0.1;\ndeny all;\nlimit_except POST { deny all; }\n"; };
                alerta-webhook-any-method = { services.nginx.virtualHosts.${vhost}.locations."= /webhook/alerta".extraConfig = lib.mkForce "allow 10.118.0.1;\ndeny all;\n"; };
                docker-enabled = { virtualisation.docker.enable = true; };
                sops-file-missing = { sops.validateSopsFiles = lib.mkOverride 40 true; };
                backup-target-missing = { automation.backup.nfsDevice = lib.mkOverride 40 null; };
                beszel-agent-listening = { services.beszel.agent.openFirewall = true; };
              };
            in
            assert lib.assertMsg (lib.all lib.id (lib.attrValues results))
              "automation exposure guards did not refuse: ${toString (lib.attrNames (lib.filterAttrs (_: ok: !ok) results))}";
            pkgs.writeText "automation-exposure-guards" (builtins.toJSON results);
        } // lib.optionalAttrs (lib.hasSuffix "-linux" system) {
          # What the agents run, which only ever runs on Linux.
          agents-packages = import ./hosts/agents/packages-check.nix { inherit pkgs; };
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
