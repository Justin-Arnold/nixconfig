# modules/roles/uptime-kuma.nix
#
# Uptime Kuma in Docker, data in the named volume `uptime-kuma` (/app/data).
# Monitors and notification integrations are runtime data managed in the UI.
{ config, lib, ... }:
let
  cfg = config.roles.uptimeKuma;
in
{
  options.roles.uptimeKuma = {
    enable = lib.mkEnableOption "Uptime Kuma";

    image = lib.mkOption {
      type = lib.types.str;
      description = "Uptime Kuma image, pinned by digest. Upgrade deliberately, not on restart.";
    };

    hostBind = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Host address Docker publishes the Kuma UI/API on.";
    };

    hostPort = lib.mkOption {
      type = lib.types.port;
      default = 3001;
      description = "Host port Docker publishes the Kuma UI/API on.";
    };

    extraHosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "notifications.host.internal:host-gateway" ];
      description = "Extra /etc/hosts entries for the container (docker --add-host).";
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.oci-containers.containers.uptime-kuma = {
      image = cfg.image;
      pull = "missing";
      autoStart = true;
      ports = [ "${cfg.hostBind}:${toString cfg.hostPort}:3001" ];
      volumes = [ "uptime-kuma:/app/data" ];
      extraOptions = map (h: "--add-host=${h}") cfg.extraHosts;
    };
  };
}
