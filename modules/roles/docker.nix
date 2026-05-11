# modules/roles/docker.nix
{ lib, config, pkgs, sops-nix ? null, ... }:
let
  cfg = config.roles.docker;
  dockhandCfg = cfg.dockhandManaged;
in {
  imports = lib.optional (sops-nix != null) sops-nix.nixosModules.sops;

  options.roles.docker = {
    enable = lib.mkEnableOption "Docker engine and tooling";
    
    # users to add to the 'docker' group (no passwords/sudo needed for docker)
    users = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ config.systemProfile.username ];
      description = "Users to add to the docker group.";
    };
    
    # install docker-compose CLI too
    enableCompose = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install docker-compose on the PATH.";
    };
    
    # use Docker as the backend for oci-containers
    setOciBackend = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Set virtualisation.oci-containers.backend = \"docker\".";
    };
    
    # optional extra daemon.json settings (in native Nix form)
    daemonSettings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      example = { "log-driver" = "json-file"; "log-opts" = { "max-size" = "50m"; }; };
      description = "Extra Docker daemon settings.";
    };
    
    # opt into rootless docker (usually keep false on servers)
    rootless = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable rootless Docker for the current users.";
    };

    dockhandManaged = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Run the Hawser agent so Dockhand can manage this Docker host.";
      };

      mode = lib.mkOption {
        type = lib.types.enum [ "standard" "edge" ];
        default = "standard";
        description = "Hawser connection mode.";
      };

      image = lib.mkOption {
        type = lib.types.str;
        default = "ghcr.io/finsys/hawser:latest";
        description = "Hawser container image.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 2376;
        description = "Host and container port for Hawser Standard mode.";
      };

      stacksDir = lib.mkOption {
        type = lib.types.str;
        default = "/opt/hawser-stacks";
        description = "Host path Hawser uses for Docker Compose stack files.";
      };

      envFile = lib.mkOption {
        type = with lib.types; nullOr (either path str);
        default = null;
        description = "Environment file containing Hawser TOKEN and optional connection settings.";
      };

      logLevel = lib.mkOption {
        type = lib.types.enum [ "debug" "info" "warn" "error" ];
        default = "info";
        description = "Hawser log level.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Docker engine
    virtualisation.docker = {
      enable = true;
      daemon.settings = cfg.daemonSettings;
      rootless = lib.mkIf cfg.rootless {
        enable = true;
        setSocketVariable = true;
      };
    };

    # Make oci-containers use Docker (so your declarative containers start automatically)
    virtualisation.oci-containers.backend = lib.mkIf cfg.setOciBackend "docker";

    # CLI tooling on PATH
    environment.systemPackages =
      [ pkgs.docker ]
      ++ lib.optional cfg.enableCompose pkgs.docker-compose;

    # Add all users (including default and specified ones) to docker group
    users.users = lib.mkMerge (
      map (u: {
        ${u}.extraGroups = [ "docker" ];
      }) cfg.users
    );

    assertions = [
      {
        assertion = sops-nix != null || !(dockhandCfg.enable && dockhandCfg.envFile == null);
        message = "roles.docker.dockhandManaged requires sops-nix or an explicit envFile.";
      }
    ];

    sops.age.keyFile = lib.mkIf (sops-nix != null && dockhandCfg.enable && dockhandCfg.envFile == null) (
      lib.mkDefault "/home/justin/.config/sops/age/keys.txt"
    );
    sops.defaultSopsFile = lib.mkIf (sops-nix != null && dockhandCfg.enable && dockhandCfg.envFile == null) (
      lib.mkDefault ../../secrets/secrets.yaml
    );
    sops.secrets."dockhand/hawser.env" = lib.mkIf (sops-nix != null && dockhandCfg.enable && dockhandCfg.envFile == null) {
      owner = "root";
      group = "root";
      mode = "0400";
    };

    systemd.tmpfiles.rules = lib.mkIf dockhandCfg.enable [
      "d ${toString dockhandCfg.stacksDir} 0750 root root -"
    ];

    virtualisation.oci-containers.containers.hawser = lib.mkIf dockhandCfg.enable {
      image = dockhandCfg.image;
      autoStart = true;
      ports = lib.mkIf (dockhandCfg.mode == "standard") [
        "${toString dockhandCfg.port}:${toString dockhandCfg.port}"
      ];
      volumes = [
        "/var/run/docker.sock:/var/run/docker.sock"
        "${toString dockhandCfg.stacksDir}:${toString dockhandCfg.stacksDir}"
      ];
      environment = {
        DOCKER_SOCKET = "/var/run/docker.sock";
        STACKS_DIR = toString dockhandCfg.stacksDir;
        AGENT_NAME = config.systemProfile.hostname;
        LOG_LEVEL = dockhandCfg.logLevel;
      } // lib.optionalAttrs (dockhandCfg.mode == "standard") {
        PORT = toString dockhandCfg.port;
      };
      environmentFiles = [
        (if dockhandCfg.envFile != null
         then dockhandCfg.envFile
         else config.sops.secrets."dockhand/hawser.env".path)
      ];
      labels = {
        "dockhand.update" = "false";
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf (dockhandCfg.enable && dockhandCfg.mode == "standard") [
      dockhandCfg.port
    ];
  };
}
