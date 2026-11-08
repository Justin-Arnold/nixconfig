# modules/roles/notifications-stack.nix
#
# Alerta (PostgreSQL + web UI) -> alerta-apprise-forwarder -> Apprise API -> ntfy,
# plus Node-RED for UI-managed intake flows. Alerta's push plugin kicks the
# forwarder as alerts come in and change, so they reach ntfy in about a
# second; notifications-stack/ holds the forwarder, the plugin and their
# tests. Extracted from
# hosts/notifications/configuration.nix; host-specific URLs, bind addresses
# and secret file paths are options so the stack can run outside the lab.
#
# Secrets are consumed only as file paths. Nothing secret is interpolated into
# the Nix store.
{ config, lib, pkgs, ... }:
let
  cfg = config.roles.notificationsStack;

  alertaPort = 5000;
  alertaWebPort = 5001;
  ntfyPort = 8080;
  apprisePort = 8000;
  appriseKey = "homelab-alerts";
  appriseForwarderPort = 9088;
  hostAliasName = "${cfg.hostAlias}.host.internal";
  alertaUrl = "http://${hostAliasName}:${toString alertaPort}";
  alertaWebUrl = "http://${hostAliasName}:${toString alertaWebPort}";

  corsOrigins = [
    "http://localhost"
    "http://localhost:${toString alertaPort}"
    "http://localhost:${toString alertaWebPort}"
    alertaUrl
    alertaWebUrl
  ] ++ cfg.alerta.extraCorsOrigins;

  secretsAfter = cfg.secrets.units;

  alertaWebui = pkgs.runCommand "alerta-webui" { } ''
    mkdir -p $out
    cp -R ${pkgs.fetchzip {
      url = "https://github.com/alerta/alerta-webui/releases/download/v7.5.0/alerta-webui.tar.gz";
      sha256 = "0854qlkqnalcwhxwgx7s59s9m3vka7w69qi0cpdlxl60av0z9qn9";
    }}/. $out/
    chmod -R u+w $out
    cat > $out/config.json <<'JSON'
    {
      "endpoint": "/api",
      "provider": "basic"
    }
    JSON
  '';

  alertaConfig = pkgs.writeText "alertad-${cfg.hostAlias}.conf" (''
    DATABASE_URL = 'postgresql:///alerta'
    DATABASE_NAME = 'alerta'
    LOG_HANDLERS = ['console']
    LOG_LEVEL = 'INFO'
    BASE_URL = '${alertaUrl}'
    SECRET_KEY = open('${cfg.secrets.alertaSecretKey}').read().strip()

    AUTH_REQUIRED = True
    AUTH_PROVIDER = 'basic'
    ADMIN_USERS = [open('${cfg.secrets.alertaAdminUser}').read().strip()]
    SIGNUP_ENABLED = False

    CORS_ORIGINS = [
    ${lib.concatMapStrings (o: "  '${o}',\n") corsOrigins}]

    ALLOWED_ENVIRONMENTS = ['Production', 'Development', 'Homelab']
    DEFAULT_ENVIRONMENT = 'Homelab'
    DEFAULT_FILTER = {'status': ['open', 'ack']}
    SORT_LIST_BY = 'lastReceiveTime'
    PLUGINS = ['push']
    # A plugin's error is logged and never fails the request that sent the alert.
    PLUGINS_RAISE_ON_ERROR = False
    FORWARDER_KICK_URL = 'http://127.0.0.1:${toString appriseForwarderPort}/kick'
  '' + lib.optionalString (cfg.alerta.n8nAlertsUrl != null) ''
    N8N_ALERTS_URL = '${cfg.alerta.n8nAlertsUrl}'
  '');

  # Alerta with the `push` plugin, which kicks the forwarder as alerts come
  # in and change (notifications-stack/alerta-push/).
  alertaServer = import ./notifications-stack/alerta-server.nix { inherit pkgs; };

  secretPathOption = description: lib.mkOption {
    type = lib.types.str;
    inherit description;
  };
in
{
  options.roles.notificationsStack = {
    enable = lib.mkEnableOption "the Alerta/Apprise/ntfy/Node-RED notification stack";

    hostAlias = lib.mkOption {
      type = lib.types.str;
      default = "notifications";
      description = ''
        Name used as <alias>.host.internal for Alerta's BASE_URL/CORS and as
        the container alias for the Docker host (host-gateway).
      '';
    };

    alerta = {
      bind = lib.mkOption {
        type = lib.types.str;
        default = "0.0.0.0";
        description = "Address the Alerta API listens on. Restrict reachability with the firewall.";
      };
      webListenAddress = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "Address the Alerta web UI (nginx) listens on.";
      };
      extraCorsOrigins = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Additional browser origins allowed to call the Alerta API.";
      };
      n8nAlertsUrl = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "https://automation.servicestack.xyz/webhook/alerta";
        description = ''
          Where the push plugin tells n8n an alert opened, with only its id,
          so n8n can decide whether the monitor triages it. Null sends nothing.
        '';
      };
    };

    ntfy = {
      baseUrl = lib.mkOption {
        type = lib.types.str;
        description = ''
          ntfy base-url. iOS poll requests are keyed by this URL plus the topic,
          so the ntfy app's server must match it exactly.
        '';
      };
      listen = lib.mkOption {
        type = lib.types.str;
        default = "0.0.0.0:${toString ntfyPort}";
        description = "ntfy listen-http address.";
      };
      behindProxy = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Trust X-Forwarded-For from a local reverse proxy (needed for per-client rate limits).";
      };
    };

    nodeRed = {
      hostBind = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "Host address Docker publishes Node-RED on.";
      };
      hostPort = lib.mkOption {
        type = lib.types.port;
        default = 1880;
        description = "Host port Docker publishes Node-RED on.";
      };
    };

    images = {
      apprise = lib.mkOption {
        type = lib.types.str;
        description = "Apprise API image, pinned by digest.";
      };
      nodeRed = lib.mkOption {
        type = lib.types.str;
        description = "Node-RED image, pinned by digest.";
      };
    };

    secrets = {
      alertaSecretKey = secretPathOption "File containing the Flask/Alerta secret key.";
      alertaAdminUser = secretPathOption "File containing the Alerta admin login.";
      alertaAdminPassword = secretPathOption "File containing the Alerta admin password.";
      alertaApiKey = secretPathOption "File containing the Alerta machine ingest API key.";
      appriseConfig = secretPathOption "Apprise text config for the ${appriseKey} key.";
      ntfyEnvironmentFile = secretPathOption "systemd EnvironmentFile with NTFY_AUTH_USERS/TOKENS/ACCESS.";
      nodeRedEnvironmentFile = secretPathOption "Docker env file with ALERTA_API_KEY for Node-RED.";
      units = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "systemd units that provide the secret files; stack units start after them.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    services.postgresql = {
      enable = true;
      ensureDatabases = [ "alerta" ];
      ensureUsers = [
        {
          name = "alerta";
          ensureDBOwnership = true;
        }
      ];
    };

    services.alerta = {
      enable = true;
      bind = cfg.alerta.bind;
      port = alertaPort;
      databaseUrl = "postgresql:///alerta";
      databaseName = "alerta";
      authenticationRequired = true;
      signupEnabled = false;
      inherit corsOrigins;
    };

    users.users.alerta.group = "alerta";

    systemd.services.alerta = {
      after = [ "network.target" "postgresql.service" "alerta-bootstrap.service" ] ++ secretsAfter;
      wants = [ "postgresql.service" ] ++ secretsAfter;
      environment.ALERTA_SVR_CONF_FILE = lib.mkForce "${alertaConfig}";
      # The push plugin reaches n8n over HTTPS, and Python doesn't find the bundle itself.
      environment.SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
      # The module runs pkgs.alerta-server, which has no push plugin.
      serviceConfig.ExecStart = lib.mkForce
        "${alertaServer}/bin/alertad run --port ${toString config.services.alerta.port} --host ${config.services.alerta.bind}";
    };

    systemd.services.alerta-bootstrap = {
      description = "Bootstrap Alerta admin user and API key";
      wantedBy = [ "multi-user.target" ];
      after = [ "postgresql.service" ] ++ secretsAfter;
      wants = [ "postgresql.service" ] ++ secretsAfter;
      before = [ "alerta.service" ];
      path = [ alertaServer pkgs.coreutils ];
      environment.ALERTA_SVR_CONF_FILE = "${alertaConfig}";
      script = ''
        admin_user="$(tr -d '\n' < ${cfg.secrets.alertaAdminUser})"
        admin_password="$(tr -d '\n' < ${cfg.secrets.alertaAdminPassword})"
        api_key="$(tr -d '\n' < ${cfg.secrets.alertaApiKey})"

        alertad user \
          --email "$admin_user" \
          --name "$admin_user" \
          --password "$admin_password" || true

        alertad key \
          --username "$admin_user" \
          --key "$api_key" \
          --scope read:alerts \
          --scope write:alerts \
          --text "Machine ingest key for homelab alert producers"
      '';
      serviceConfig = {
        Type = "oneshot";
        User = "alerta";
        Group = "alerta";
      };
    };

    services.ntfy-sh = {
      enable = true;
      environmentFile = cfg.secrets.ntfyEnvironmentFile;
      settings = {
        base-url = cfg.ntfy.baseUrl;
        upstream-base-url = "https://ntfy.sh";
        listen-http = cfg.ntfy.listen;
        auth-default-access = "deny-all";
        enable-login = true;
      } // lib.optionalAttrs cfg.ntfy.behindProxy {
        behind-proxy = true;
      };
    };

    systemd.services.ntfy-sh = {
      after = secretsAfter;
      wants = secretsAfter;
      preStart = ''
        # ntfy declarative token provisioning is not idempotent against an existing
        # auth DB. Keep users, tokens, and ACLs sourced from the env file on each start.
        rm -f /var/lib/ntfy-sh/user.db
      '';
    };

    services.nginx = {
      enable = true;
      recommendedGzipSettings = true;
      virtualHosts.alerta-webui = {
        listen = [
          {
            addr = cfg.alerta.webListenAddress;
            port = alertaWebPort;
          }
        ];
        root = alertaWebui;
        locations."/api/".proxyPass = "http://127.0.0.1:${toString alertaPort}/";
        locations."/".tryFiles = "$uri $uri/ /index.html";
      };
    };

    systemd.tmpfiles.rules = [
      "d /opt/apprise/config 0750 1000 1000 -"
      "d /opt/apprise/plugin 0750 1000 1000 -"
      "d /opt/apprise/attach 0750 1000 1000 -"
      "d /opt/node-red/data 0750 1000 1000 -"
    ];

    virtualisation.oci-containers.containers.apprise = {
      image = cfg.images.apprise;
      autoStart = true;
      ports = [ "127.0.0.1:${toString apprisePort}:8000" ];
      volumes = [
        "/opt/apprise/config:/config"
        "/opt/apprise/plugin:/plugin"
        "/opt/apprise/attach:/attach"
        "${cfg.secrets.appriseConfig}:/config/${appriseKey}.cfg:ro"
      ];
      environment = {
        APPRISE_STATEFUL_MODE = "simple";
        APPRISE_WORKER_COUNT = "1";
        APPRISE_ADMIN = "y";
        TZ = config.systemProfile.timeZone;
      };
      extraOptions = [
        "--add-host=${hostAliasName}:host-gateway"
      ];
    };

    virtualisation.oci-containers.containers.node-red = {
      image = cfg.images.nodeRed;
      autoStart = true;
      ports = [ "${cfg.nodeRed.hostBind}:${toString cfg.nodeRed.hostPort}:1880" ];
      volumes = [
        "/opt/node-red/data:/data"
      ];
      environmentFiles = [
        cfg.secrets.nodeRedEnvironmentFile
      ];
      environment = {
        TZ = config.systemProfile.timeZone;
      };
      extraOptions = [
        "--add-host=${hostAliasName}:host-gateway"
      ];
    };

    systemd.services.docker-apprise = {
      after = secretsAfter;
      wants = secretsAfter;
    };

    systemd.services.docker-node-red = {
      after = secretsAfter;
      wants = secretsAfter;
    };

    # Kicked by Alerta's push plugin as alerts come in and change, so it reads
    # Alerta within a second. The poll is a sweep behind that, and a pass that
    # went wrong tries again after RETRY_SECONDS.
    systemd.services.alerta-apprise-forwarder = {
      description = "Forward processed Alerta alerts to Apprise API";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" "docker-apprise.service" ] ++ secretsAfter;
      wants = [ "docker-apprise.service" ] ++ secretsAfter;
      environment = {
        APPRISE_BASE_URL = "http://127.0.0.1:${toString apprisePort}";
        APPRISE_KEY = appriseKey;
        ALERTA_BASE_URL = "http://127.0.0.1:${toString alertaPort}";
        ALERTA_API_KEY_FILE = cfg.secrets.alertaApiKey;
        LISTEN_ADDR = "127.0.0.1";
        LISTEN_PORT = toString appriseForwarderPort;
        POLL_INTERVAL_SECONDS = "300";
        RETRY_SECONDS = "15";
        CLOSED_ALERT_LOOKBACK_SECONDS = "3600";
        STATE_FILE = "/var/lib/alerta-apprise-forwarder/state.json";
      };
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 -I ${./notifications-stack/forwarder.py}";
        Restart = "always";
        RestartSec = "10s";
        User = "root";
        Group = "root";
        StateDirectory = "alerta-apprise-forwarder";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
      };
    };

    environment.systemPackages = with pkgs; [
      alerta
      curl
      jq
      ntfy-sh
    ];
  };
}
