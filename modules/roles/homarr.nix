# modules/roles/homarr.nix
#
# Homarr (https://homarr.dev) in Docker. Boards, apps, users and integration
# credentials are runtime data in SQLite under dataDir, which is /appdata in
# the container. Integration secrets in that database are encrypted with
# SECRET_ENCRYPTION_KEY, so the key has to stay the same for as long as the
# data exists. Losing it means re-entering every integration credential.
#
# The key is bind-mounted read-only and read through SECRET_ENCRYPTION_KEY_FILE,
# so it never shows up in `docker inspect`. No Docker socket is mounted and
# Homarr's Docker features are off. The container publishes on 127.0.0.1 by
# default; put a reverse proxy in front of it.
{ config, lib, pkgs, ... }:
let
  cfg = config.roles.homarr;

  keyInContainer = "/run/secrets/homarr-secret-encryption-key";
  keyPin = "${cfg.dataDir}/.secret-encryption-key.sha256";

  # Runs before every start. Refuses a malformed key, and refuses a key that
  # differs from the one the existing data was created with, instead of
  # letting Homarr start with integrations it can no longer decrypt.
  keyGuard = pkgs.writeShellApplication {
    name = "homarr-key-guard";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      key="$(tr -d '\n' < ${lib.escapeShellArg cfg.secretEncryptionKeyFile})"
      if ! [[ "$key" =~ ^[0-9a-fA-F]{64}$ ]]; then
        echo "homarr: SECRET_ENCRYPTION_KEY must be 64 hex characters (openssl rand -hex 32)." >&2
        exit 1
      fi
      sum="$(printf '%s' "$key" | sha256sum | cut -d' ' -f1)"
      unset key
      if [[ -f ${keyPin} ]]; then
        if [[ "$(cat ${keyPin})" != "$sum" ]]; then
          echo "homarr: SECRET_ENCRYPTION_KEY is not the key this data was created with." >&2
          echo "Restore the original key, or move ${cfg.dataDir} aside to start fresh." >&2
          exit 1
        fi
      else
        printf '%s\n' "$sum" > ${keyPin}
        chmod 0644 ${keyPin}
      fi
    '';
  };
in
{
  options.roles.homarr = {
    enable = lib.mkEnableOption "Homarr";

    image = lib.mkOption {
      type = lib.types.str;
      description = "Homarr image, pinned by digest. Upgrade deliberately, after a backup.";
    };

    baseUrl = lib.mkOption {
      type = lib.types.str;
      example = "https://dashboard.example.com";
      description = ''
        Public origin with no path (BASE_URL). Homarr uses it for origin checks,
        secure cookies and MCP OAuth metadata, so every way of reaching Homarr
        has to present this exact origin.
      '';
    };

    hostBind = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Host address Docker publishes Homarr on.";
    };

    hostPort = lib.mkOption {
      type = lib.types.port;
      default = 7575;
      description = "Host port Docker publishes Homarr on.";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/homarr";
      description = "Host directory mounted as /appdata (database, Redis snapshot, trusted certificates).";
    };

    uid = lib.mkOption {
      type = lib.types.int;
      default = 7575;
      description = "UID the container drops to (PUID) and that owns dataDir.";
    };

    gid = lib.mkOption {
      type = lib.types.int;
      default = 7575;
      description = "GID the container drops to (PGID).";
    };

    secretEncryptionKeyFile = lib.mkOption {
      type = lib.types.str;
      description = "File holding SECRET_ENCRYPTION_KEY (64 hex characters), e.g. a sops-nix secret.";
    };

    trustedProxies = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "172.17.0.1" ];
      description = ''
        Addresses whose X-Forwarded-For Homarr trusts (HOMARR_TRUSTED_PROXIES).
        A proxy on the host reaches the container from the Docker bridge
        gateway.
      '';
    };

    extraHosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "beszel.example.com:host-gateway" ];
      description = "Extra /etc/hosts entries for the container (docker --add-host).";
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra non-secret environment variables.";
    };

    healthWatch.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Restart the container when Docker's health check (/api/health/live,
        which checks the database and Redis) keeps failing. systemd already
        restarts it when it exits; this covers a process that hangs.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.homarr.gid = cfg.gid;
    users.users.homarr = {
      isSystemUser = true;
      uid = cfg.uid;
      group = "homarr";
      description = "Homarr container user";
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 homarr homarr -"
    ];

    virtualisation.oci-containers.containers.homarr = {
      image = cfg.image;
      pull = "missing";
      autoStart = true;
      ports = [ "${cfg.hostBind}:${toString cfg.hostPort}:7575" ];
      volumes = [
        "${cfg.dataDir}:/appdata"
        "${cfg.secretEncryptionKeyFile}:${keyInContainer}:ro"
      ];
      environment = {
        BASE_URL = cfg.baseUrl;
        PUID = toString cfg.uid;
        PGID = toString cfg.gid;
        SECRET_ENCRYPTION_KEY_FILE = keyInContainer;
        HOMARR_TRUSTED_PROXIES = lib.concatStringsSep "," cfg.trustedProxies;
        # No update checks, weather, RSS or the analytics that are on by default.
        NO_EXTERNAL_CONNECTION = "true";
        # The Docker page needs the socket, which this container doesn't get.
        ENABLE_DOCKER = "false";
        AUTH_PROVIDERS = "credentials";
        LOG_LEVEL = "info";
        TZ = config.systemProfile.timeZone;
      } // cfg.environment;
      extraOptions = [ "--security-opt=no-new-privileges" ]
        ++ map (h: "--add-host=${h}") cfg.extraHosts;
    };

    systemd.services.docker-homarr = {
      after = [ "systemd-tmpfiles-setup.service" ];
      serviceConfig = {
        ExecStartPre = lib.mkBefore [ "${keyGuard}/bin/homarr-key-guard" ];
        Restart = lib.mkForce "always";
        RestartSec = "10s";
      };
    };

    systemd.services.homarr-health-watch = lib.mkIf cfg.healthWatch.enable {
      description = "Restart Homarr when its health check keeps failing";
      path = [ config.virtualisation.docker.package pkgs.coreutils config.systemd.package ];
      serviceConfig.Type = "oneshot";
      script = ''
        status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' homarr 2>/dev/null || true)"
        [[ "$status" == "unhealthy" ]] || exit 0

        # At most one restart per 15 minutes, so a broken upgrade doesn't loop.
        stamp=/run/homarr-health-watch.last
        now="$(date +%s)"
        if [[ -f "$stamp" ]] && (( now - $(cat "$stamp") < 900 )); then
          echo "homarr is unhealthy, but was restarted less than 15 minutes ago"
          exit 0
        fi
        echo "$now" > "$stamp"
        echo "homarr is unhealthy; restarting docker-homarr.service"
        systemctl restart docker-homarr.service
      '';
    };

    systemd.timers.homarr-health-watch = lib.mkIf cfg.healthWatch.enable {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "10min";
        OnUnitActiveSec = "2min";
      };
    };
  };
}
