# modules/roles/beszel-agent.nix
#
# Beszel agent (services.beszel.agent) reporting to the hub on the dashboard
# host. The agent dials out to the hub over WebSocket and never listens:
# DISABLE_SSH stops the SSH server it would otherwise fall back to on 45876.
# KEY is the hub's public key and isn't secret; TOKEN is, and comes from an
# environment file (a sops-nix template, or a file another role renders).
#
# Container stats are off. They need the Docker API, and the calls the agent
# makes (inspect, logs) expose every container's environment and output, so
# the docker group the upstream module adds is taken away again.
#
# With hubPublicKey set to null the agent stays off and the build prints a
# warning.
{ config, lib, ... }:
let
  cfg = config.roles.beszelAgent;
  active = cfg.enable && cfg.hubPublicKey != null;
  useSops = cfg.tokenSecret != null;
in
{
  options.roles.beszelAgent = {
    enable = lib.mkEnableOption "the Beszel monitoring agent";

    hubUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://beszel.servicestack.xyz";
      description = "Hub URL the agent connects to (HUB_URL).";
    };

    hubPublicKey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      # The dashboard hub's key (beszel/hub-private-key in its SOPS file).
      default = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMOw68emIRvFIytDPVQbJRS0et+o1KedYFcvQvo6qv6v beszel-hub";
      description = "The hub's public key (KEY). The agent only accepts a hub that holds the matching private key.";
    };

    tokenSecret = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "beszel/agent-token";
      description = "sops-nix secret holding the agent token. Mutually exclusive with environmentFile.";
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Existing file with a TOKEN=... line. Mutually exclusive with tokenSecret.";
    };

    systemName = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "Name the system registers under in the hub.";
    };

    gpu.nvidia = lib.mkOption {
      type = lib.types.bool;
      default = builtins.elem "nvidia" config.services.xserver.videoDrivers;
      description = "Give the agent the NVIDIA device nodes so nvidia-smi can report GPU usage.";
    };

    extraEnvironment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra agent environment variables (e.g. EXTRA_FILESYSTEMS).";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (cfg.enable && cfg.hubPublicKey == null) {
      warnings = [
        "roles.beszelAgent: hubPublicKey is not set yet, so the Beszel agent on ${config.networking.hostName} stays off."
      ];
    })

    (lib.mkIf active {
      assertions = [
        {
          assertion = (cfg.tokenSecret == null) != (cfg.environmentFile == null);
          message = "roles.beszelAgent: set exactly one of tokenSecret and environmentFile.";
        }
        {
          assertion = !config.services.beszel.agent.openFirewall;
          message = "roles.beszelAgent: the agent connects out to the hub and must not open a port.";
        }
      ];

      sops.secrets = lib.mkIf useSops {
        ${cfg.tokenSecret}.restartUnits = [ "beszel-agent.service" ];
      };
      sops.templates = lib.mkIf useSops {
        "beszel-agent.env" = {
          content = "TOKEN=${config.sops.placeholder.${cfg.tokenSecret}}\n";
          restartUnits = [ "beszel-agent.service" ];
        };
      };

      services.beszel.agent = {
        enable = true;
        environmentFile = if useSops then config.sops.templates."beszel-agent.env".path else cfg.environmentFile;
        environment = {
          HUB_URL = cfg.hubUrl;
          KEY = cfg.hubPublicKey;
          DISABLE_SSH = "true";
          SYSTEM_NAME = cfg.systemName;
          # Empty means no Docker or Podman API at all.
          DOCKER_HOST = "";
          DATA_DIR = "/var/lib/beszel-agent";
          LOG_LEVEL = "info";
        } // cfg.extraEnvironment;
      };

      systemd.services.beszel-agent = {
        after = lib.optional cfg.gpu.nvidia "nvidia-persistenced.service";
        serviceConfig = {
          SupplementaryGroups = lib.mkForce [ ];
          StateDirectory = "beszel-agent";
        } // lib.optionalAttrs cfg.gpu.nvidia {
          # nvidia-smi needs the real device nodes; allow only the NVIDIA ones.
          PrivateDevices = lib.mkForce false;
          DevicePolicy = "closed";
          DeviceAllow = [
            "/dev/nvidiactl rw"
            "/dev/nvidia0 rw"
            "/dev/nvidia-uvm rw"
            "/dev/nvidia-uvm-tools rw"
            "/dev/nvidia-modeset rw"
          ];
        };
      };
    })
  ];
}
