# modules/roles/docker.nix
{ lib, config, pkgs, ... }:
let
  cfg = config.roles.docker;
in {
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
    virtualisation.oci-containers = lib.mkIf cfg.setOciBackend {
      backend = "docker";
    };

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
  };
}