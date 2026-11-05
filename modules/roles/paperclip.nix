# modules/roles/paperclip.nix
#
# Paperclip (https://paperclip.ing), the agent orchestration server, from the
# official image under Podman, against a native PostgreSQL. Companies, agents,
# issues, approvals, budgets and the activity log live in the database;
# attachments, instance config and agent home files live in dataDir, which is
# /paperclip in the container.
#
# It runs in `authenticated` mode with `private` exposure: a login is
# required, and the first admin comes from a one-time invite URL the server
# prints at first start, not from whoever visits first. It listens on
# 127.0.0.1 only (host network, so it reaches the database and anything else
# on loopback); put a reverse proxy in front of it.
#
# The container runs as a fixed unprivileged UID from the first process on,
# so the image's entrypoint never runs as root or chowns anything. Secrets
# reach it through a root-only environment file rendered by sops-nix and a
# read-only bind mount for the master key, never through `environment`
# (which ends up in the Nix store).
#
# Paperclip's local adapters (claude_local, codex_local, hermes_local,
# process) run agent CLIs inside this container with the server's own
# privileges. Agents here are meant to use the remote adapters instead
# (hermes_gateway, openclaw_gateway), so nothing in the image is logged in to
# a model provider.
{ config, lib, pkgs, ... }:
let
  cfg = config.roles.paperclip;
  oci = config.virtualisation.oci-containers;
  unit = "${oci.backend}-paperclip.service";

  masterKeyInContainer = "/run/secrets/paperclip-master-key";
  masterKeyFile = config.sops.secrets.${cfg.secrets.masterKey}.path;
  keyPin = "${cfg.dataDir}/.master-key.sha256";

  # Runs before every start. Refuses a malformed master key, and refuses a
  # key that differs from the one the existing data was encrypted with,
  # instead of letting Paperclip start with stored secrets it can't read.
  keyGuard = pkgs.writeShellApplication {
    name = "paperclip-key-guard";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      key="$(tr -d '\n' < ${lib.escapeShellArg masterKeyFile})"
      if ! [[ "$key" =~ ^[0-9a-fA-F]{64}$ ]]; then
        echo "paperclip: the master key must be 64 hex characters (openssl rand -hex 32)." >&2
        exit 1
      fi
      sum="$(printf '%s' "$key" | sha256sum | cut -d' ' -f1)"
      unset key
      if [[ -f ${keyPin} ]]; then
        if [[ "$(cat ${keyPin})" != "$sum" ]]; then
          echo "paperclip: the master key is not the key this data was encrypted with." >&2
          echo "Restore the original key, or move ${cfg.dataDir} aside and drop the database to start fresh." >&2
          exit 1
        fi
      else
        printf '%s\n' "$sum" > ${keyPin}
        chmod 0644 ${keyPin}
      fi
    '';
  };
  dbUrl = "postgres://paperclip:${config.sops.placeholder.${cfg.secrets.databasePassword}}@127.0.0.1:${toString config.services.postgresql.settings.port}/paperclip";

  # Sets the database role's password from SOPS before every start, so the
  # value in SOPS is always the one that works. psql reads the file itself
  # (a backtick in \set), so the password never appears in an argv.
  setDbPassword = pkgs.writeShellScript "paperclip-db-password" ''
    set -eu
    ${config.services.postgresql.package}/bin/psql -v ON_ERROR_STOP=1 -q <<'SQL'
    \set pw `cat "$CREDENTIALS_DIRECTORY/db-password"`
    ALTER ROLE paperclip WITH LOGIN PASSWORD :'pw';
    SQL
  '';
in
{
  options.roles.paperclip = {
    enable = lib.mkEnableOption "Paperclip";

    image = lib.mkOption {
      type = lib.types.str;
      description = "Paperclip image, pinned by digest. Upgrade deliberately, after a backup: migrations only go forward.";
    };

    publicUrl = lib.mkOption {
      type = lib.types.str;
      example = "https://paperclip.example.com";
      description = ''
        The origin people and agents use (PAPERCLIP_PUBLIC_URL). Paperclip
        derives auth callbacks, cookies, invite links and the API URL it hands
        to agents from it, and adds its hostname to the allowed hostnames.
      '';
    };

    allowedHostnames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Hostnames accepted in addition to publicUrl's (PAPERCLIP_ALLOWED_HOSTNAMES).";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3100;
      description = "Port Paperclip listens on, on 127.0.0.1.";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/paperclip";
      description = "Host directory mounted as /paperclip (instance config, attachments, agent home files).";
    };

    uid = lib.mkOption {
      type = lib.types.int;
      default = 3100;
      description = "UID the container runs as and that owns dataDir.";
    };

    gid = lib.mkOption {
      type = lib.types.int;
      default = 3100;
      description = "GID the container runs as.";
    };

    signUp.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Allow new accounts (PAPERCLIP_AUTH_DISABLE_SIGN_UP=false). The first
        admin has to create an account to accept the bootstrap invite, so it
        has to be on until the board is claimed. Turn it off afterwards;
        further users can't sign up while it's off.
      '';
    };

    secrets = {
      betterAuthSecret = lib.mkOption {
        type = lib.types.str;
        default = "paperclip/better-auth-secret";
        description = "sops secret holding BETTER_AUTH_SECRET (signs sessions). `openssl rand -hex 32`.";
      };
      agentJwtSecret = lib.mkOption {
        type = lib.types.str;
        default = "paperclip/agent-jwt-secret";
        description = "sops secret holding PAPERCLIP_AGENT_JWT_SECRET (signs agent run tokens). `openssl rand -hex 32`.";
      };
      masterKey = lib.mkOption {
        type = lib.types.str;
        default = "paperclip/master-key";
        description = ''
          sops secret holding the master key that encrypts every secret
          stored in Paperclip (64 hex characters, `openssl rand -hex 32`).
          Never change it while the data exists.
        '';
      };
      databasePassword = lib.mkOption {
        type = lib.types.str;
        default = "paperclip/database-password";
        description = "sops secret holding the database role's password. Hex only (`openssl rand -hex 32`), since it goes into a URL unescaped.";
      };
    };

    memory = lib.mkOption {
      type = lib.types.str;
      default = "4g";
      description = "Container memory limit (podman --memory).";
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra non-secret environment variables.";
    };

    masterKeyPinFile = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = keyPin;
      description = "sha256 of the master key, written on first start. Backups carry it so a restore can refuse mismatched data.";
    };

    healthWatch.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Restart the container when /api/health stops answering for three
        checks in a row. systemd already restarts it when it exits; this
        covers a process that hangs. It leaves a container that started less
        than 15 minutes ago alone, so a long migration isn't interrupted.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = oci.backend == "podman";
        message = "roles.paperclip runs under Podman (virtualisation.oci-containers.backend = \"podman\").";
      }
      {
        assertion = lib.hasPrefix "https://" cfg.publicUrl;
        message = "roles.paperclip.publicUrl must be https: secure cookies and the MCP endpoint need it.";
      }
      {
        assertion = lib.all (k: !(cfg.environment ? ${k})) [
          "BETTER_AUTH_SECRET" "PAPERCLIP_AGENT_JWT_SECRET" "PAPERCLIP_SECRETS_MASTER_KEY" "DATABASE_URL"
          "PAPERCLIP_DEPLOYMENT_MODE" "PAPERCLIP_BIND" "HOST"
        ];
        message = "roles.paperclip.environment may not set secrets, the deployment mode or the bind address; the role owns those.";
      }
    ];

    users.groups.paperclip.gid = cfg.gid;
    users.users.paperclip = {
      isSystemUser = true;
      uid = cfg.uid;
      group = "paperclip";
      description = "Paperclip container user";
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 paperclip paperclip -"
    ];

    ############################################################
    ## Database
    ############################################################
    # The server only listens on the socket and localhost. Only the
    # superuser (peer, on the socket) and the paperclip role (password, from
    # 127.0.0.1) can connect; nothing else on the host has a way in.
    services.postgresql = {
      enable = true;
      # Pinned, so a stateVersion bump never changes the major version under
      # existing data. A major upgrade is a dump and restore.
      package = pkgs.postgresql_17;
      enableTCPIP = false;
      ensureDatabases = [ "paperclip" ];
      ensureUsers = [
        {
          name = "paperclip";
          ensureDBOwnership = true;
        }
      ];
      authentication = lib.mkForce ''
        # TYPE  DATABASE   USER       ADDRESS        METHOD
        local   all        postgres                  peer
        host    paperclip  paperclip  127.0.0.1/32   scram-sha-256
      '';
      settings.password_encryption = "scram-sha-256";
    };

    systemd.services.paperclip-db-password = {
      description = "Set the Paperclip database password from SOPS";
      after = [ "postgresql.service" "postgresql-setup.service" ];
      requires = [ "postgresql.service" ];
      wants = [ "postgresql-setup.service" ];
      before = [ unit ];
      requiredBy = [ unit ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "postgres";
        LoadCredential = [ "db-password:${config.sops.secrets.${cfg.secrets.databasePassword}.path}" ];
        ExecStart = setDbPassword;
      };
    };

    ############################################################
    ## Secrets
    ############################################################
    sops.secrets.${cfg.secrets.betterAuthSecret} = { };
    sops.secrets.${cfg.secrets.agentJwtSecret} = { };
    sops.secrets.${cfg.secrets.databasePassword}.restartUnits = [ "paperclip-db-password.service" unit ];
    # Read by the container's user through the bind mount. Paperclip warns
    # unless group and other have no access.
    sops.secrets.${cfg.secrets.masterKey} = {
      owner = "paperclip";
      mode = "0400";
      restartUnits = [ unit ];
    };
    sops.templates."paperclip.env" = {
      content = ''
        BETTER_AUTH_SECRET=${config.sops.placeholder.${cfg.secrets.betterAuthSecret}}
        PAPERCLIP_AGENT_JWT_SECRET=${config.sops.placeholder.${cfg.secrets.agentJwtSecret}}
        DATABASE_URL=${dbUrl}
      '';
      restartUnits = [ unit ];
    };

    ############################################################
    ## Container
    ############################################################
    virtualisation.oci-containers.containers.paperclip = {
      image = cfg.image;
      pull = "missing";
      autoStart = true;
      user = "${toString cfg.uid}:${toString cfg.gid}";
      volumes = [
        "${cfg.dataDir}:/paperclip"
        "${masterKeyFile}:${masterKeyInContainer}:ro"
      ];
      environmentFiles = [ config.sops.templates."paperclip.env".path ];
      environment = {
        HOME = "/paperclip";
        PAPERCLIP_HOME = "/paperclip";
        HOST = "127.0.0.1";
        PORT = toString cfg.port;
        PAPERCLIP_BIND = "loopback";
        SERVE_UI = "true";
        PAPERCLIP_DEPLOYMENT_MODE = "authenticated";
        PAPERCLIP_DEPLOYMENT_EXPOSURE = "private";
        PAPERCLIP_PUBLIC_URL = cfg.publicUrl;
        PAPERCLIP_AUTH_BASE_URL_MODE = "explicit";
        PAPERCLIP_AUTH_DISABLE_SIGN_UP = lib.boolToString (!cfg.signUp.enable);
        PAPERCLIP_SECRETS_PROVIDER = "local_encrypted";
        PAPERCLIP_SECRETS_MASTER_KEY_FILE = masterKeyInContainer;
        PAPERCLIP_SECRETS_STRICT_MODE = "true";
        # The nightly dump (roles.sqliteBackup) covers the database; the
        # built-in hourly dumps would only pile up in dataDir.
        PAPERCLIP_DB_BACKUP_ENABLED = "false";
        # No usage telemetry and no announcements feed.
        PAPERCLIP_TELEMETRY_DISABLED = "1";
        DO_NOT_TRACK = "1";
        PAPERCLIP_ANNOUNCEMENTS_ENABLED = "false";
        TZ = config.systemProfile.timeZone;
      } // lib.optionalAttrs (cfg.allowedHostnames != [ ]) {
        PAPERCLIP_ALLOWED_HOSTNAMES = lib.concatStringsSep "," cfg.allowedHostnames;
      } // cfg.environment;
      extraOptions = [
        "--network=host"
        "--security-opt=no-new-privileges"
        "--cap-drop=all"
        "--memory=${cfg.memory}"
        # Agent runs spawn processes; a leak hits this ceiling instead of
        # the host's.
        "--pids-limit=2048"
        # Paperclip waits up to 30 s for running adapters to settle.
        "--stop-timeout=90"
      ];
    };

    systemd.services.${lib.removeSuffix ".service" unit} = {
      after = [ "systemd-tmpfiles-setup.service" "postgresql.service" ];
      requires = [ "postgresql.service" ];
      serviceConfig = {
        ExecStartPre = lib.mkBefore [ "${keyGuard}/bin/paperclip-key-guard" ];
        Restart = lib.mkForce "always";
        RestartSec = "10s";
      };
    };

    systemd.services.paperclip-health-watch = lib.mkIf cfg.healthWatch.enable {
      description = "Restart Paperclip when its health check keeps failing";
      path = [ pkgs.coreutils pkgs.curl config.systemd.package ];
      serviceConfig.Type = "oneshot";
      script = ''
        fails=/run/paperclip-health-watch.fails
        if curl -fsS -o /dev/null --max-time 10 http://127.0.0.1:${toString cfg.port}/api/health; then
          rm -f "$fails"
          exit 0
        fi
        n=$(( $(cat "$fails" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$fails"
        echo "paperclip health check failed ($n in a row)"
        (( n >= 3 )) || exit 0

        # Leave a fresh start alone: migrations run before the server answers.
        started="$(systemctl show -P ActiveEnterTimestampMonotonic ${unit})"
        now="$(cut -d' ' -f1 /proc/uptime | cut -d. -f1)"
        if (( started == 0 || now - started / 1000000 < 900 )); then
          echo "${unit} started less than 15 minutes ago; not restarting"
          exit 0
        fi

        # At most one restart per 15 minutes, so a broken upgrade doesn't loop.
        stamp=/run/paperclip-health-watch.last
        if [[ -f "$stamp" ]] && (( now - $(cat "$stamp") < 900 )); then
          echo "paperclip was restarted less than 15 minutes ago; not again"
          exit 0
        fi
        echo "$now" > "$stamp"
        rm -f "$fails"
        echo "restarting ${unit}"
        systemctl restart ${unit}
      '';
    };

    systemd.timers.paperclip-health-watch = lib.mkIf cfg.healthWatch.enable {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "10min";
        OnUnitActiveSec = "2min";
      };
    };
  };
}
