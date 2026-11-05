# modules/roles/notifications-stack.nix
#
# Alerta (PostgreSQL + web UI) -> alerta-apprise-forwarder -> Apprise API -> ntfy,
# plus Node-RED for UI-managed intake flows. Extracted from
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

  alertaConfig = pkgs.writeText "alertad-${cfg.hostAlias}.conf" ''
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
    PLUGINS = []
  '';

  alertaAppriseForwarder = pkgs.writeText "alerta-apprise-forwarder.py" ''
    #!/usr/bin/env python3
    import hashlib
    import json
    import os
    import sys
    import threading
    import time
    import urllib.error
    import urllib.parse
    import urllib.request
    from datetime import datetime, timedelta, timezone
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    APPRISE_BASE_URL = os.environ.get("APPRISE_BASE_URL", "http://127.0.0.1:${toString apprisePort}")
    APPRISE_KEY = os.environ.get("APPRISE_KEY", "${appriseKey}")
    ALERTA_BASE_URL = os.environ.get("ALERTA_BASE_URL", "http://127.0.0.1:${toString alertaPort}")
    ALERTA_API_KEY_FILE = os.environ.get("ALERTA_API_KEY_FILE")
    LISTEN_ADDR = os.environ.get("LISTEN_ADDR", "127.0.0.1")
    LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "${toString appriseForwarderPort}"))
    POLL_INTERVAL_SECONDS = int(os.environ.get("POLL_INTERVAL_SECONDS", "15"))
    CLOSED_ALERT_LOOKBACK_SECONDS = int(os.environ.get("CLOSED_ALERT_LOOKBACK_SECONDS", "3600"))
    STATE_FILE = os.environ.get("STATE_FILE", "/var/lib/alerta-apprise-forwarder/state.json")

    TYPE_BY_SEVERITY = {
        "critical": "failure",
        "major": "failure",
        "security": "failure",
        "minor": "warning",
        "warning": "warning",
        "normal": "success",
        "ok": "success",
        "cleared": "success",
    }

    def apprise_type(severity):
        return TYPE_BY_SEVERITY.get(str(severity or "").lower(), "info")

    def alert_attributes(alert):
        return alert.get("attributes") or {}

    def alert_title(alert):
        attributes = alert_attributes(alert)
        if attributes.get("notificationTitle"):
            return str(attributes["notificationTitle"])
        severity = str(alert.get("severity") or "unknown").upper()
        resource = alert.get("resource") or "unknown-resource"
        event = alert.get("event") or "unknown-event"
        return f"[{severity}] {resource}: {event}"

    def alert_body(alert):
        attributes = alert_attributes(alert)
        if attributes.get("notificationBody"):
            return str(attributes["notificationBody"])
        fields = [
            ("text", alert.get("text")),
            ("service", ", ".join(alert.get("service") or [])),
            ("environment", alert.get("environment")),
            ("group", alert.get("group")),
            ("origin", alert.get("origin")),
            ("value", alert.get("value")),
            ("tags", ", ".join(alert.get("tags") or [])),
            ("id", alert.get("id")),
        ]
        return "\n".join(f"{name}: {value}" for name, value in fields if value)

    def notify_apprise(alert):
        payload = {
            "title": alert_title(alert),
            "body": alert_body(alert) or alert_title(alert),
            "type": apprise_type(alert.get("severity")),
            "format": "text",
        }
        data = json.dumps(payload).encode("utf-8")
        request = urllib.request.Request(
            f"{APPRISE_BASE_URL}/notify/{APPRISE_KEY}",
            data=data,
            headers={
                "Content-Type": "application/json",
                "Accept": "application/json",
            },
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=10) as response:
            response.read()
            return response.status

    def read_alerta_key():
        if not ALERTA_API_KEY_FILE:
            raise RuntimeError("ALERTA_API_KEY_FILE is not set")
        with open(ALERTA_API_KEY_FILE, "r", encoding="utf-8") as handle:
            return handle.read().strip()

    def fetch_alerts():
        query = urllib.parse.urlencode([
            ("status", "open"),
            ("status", "ack"),
            ("status", "closed"),
        ])
        request = urllib.request.Request(
            f"{ALERTA_BASE_URL}/alerts?{query}",
            headers={
                "Authorization": f"Key {read_alerta_key()}",
                "Accept": "application/json",
            },
            method="GET",
        )
        with urllib.request.urlopen(request, timeout=10) as response:
            payload = json.loads(response.read().decode("utf-8"))
            return payload.get("alerts", [])

    def alert_fingerprint(alert):
        parts = {
            "id": alert.get("id"),
            "severity": alert.get("severity"),
            "status": alert.get("status"),
            "text": alert.get("text"),
            "title": alert_attributes(alert).get("notificationTitle"),
            "body": alert_attributes(alert).get("notificationBody"),
        }
        return hashlib.sha256(json.dumps(parts, sort_keys=True).encode("utf-8")).hexdigest()

    def parse_alert_time(value):
        if not value:
            return None
        try:
            return datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        except ValueError:
            return None

    def should_skip_closed_alert(alert):
        if str(alert.get("status") or "").lower() != "closed":
            return False

        last_seen = parse_alert_time(alert.get("lastReceiveTime")) or parse_alert_time(alert.get("receiveTime"))
        if not last_seen:
            return False

        return datetime.now(timezone.utc) - last_seen > timedelta(seconds=CLOSED_ALERT_LOOKBACK_SECONDS)

    def load_state():
        try:
            with open(STATE_FILE, "r", encoding="utf-8") as handle:
                return json.load(handle)
        except FileNotFoundError:
            return {}
        except Exception as exc:
            print(f"failed to load state: {exc}", file=sys.stderr)
            return {}

    def save_state(state):
        os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
        tmp = f"{STATE_FILE}.tmp"
        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump(state, handle, sort_keys=True)
        os.replace(tmp, STATE_FILE)

    def poll_alerta():
        state = load_state()
        while True:
            try:
                changed = False
                for alert in fetch_alerts():
                    alert_id = alert.get("id")
                    if not alert_id:
                        continue
                    fingerprint = alert_fingerprint(alert)
                    if state.get(alert_id) == fingerprint:
                        continue
                    if should_skip_closed_alert(alert):
                        state[alert_id] = fingerprint
                        changed = True
                        continue
                    notify_apprise(alert)
                    state[alert_id] = fingerprint
                    changed = True
                if changed:
                    save_state(state)
            except Exception as exc:
                print(f"poll failed: {exc}", file=sys.stderr)
            time.sleep(POLL_INTERVAL_SECONDS)

    def apprise_health():
        request = urllib.request.Request(f"{APPRISE_BASE_URL}/status", method="GET")
        with urllib.request.urlopen(request, timeout=5) as response:
            response.read()
            return response.status

    class Handler(BaseHTTPRequestHandler):
        server_version = "alerta-apprise-forwarder/1.0"

        def log_message(self, fmt, *args):
            print(f"{self.address_string()} - {fmt % args}", file=sys.stderr)

        def json_response(self, status, payload):
            body = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path != "/healthz":
                self.json_response(404, {"status": "not_found"})
                return
            try:
                apprise_status = apprise_health()
                self.json_response(200, {"status": "ok", "apprise_status": apprise_status})
            except Exception as exc:
                self.json_response(503, {"status": "error", "error": str(exc)})

        def do_POST(self):
            if self.path != "/alert":
                self.json_response(404, {"status": "not_found"})
                return

            try:
                length = int(self.headers.get("Content-Length", "0"))
                alert = json.loads(self.rfile.read(length).decode("utf-8"))
                status = notify_apprise(alert)
                self.json_response(200, {"status": "ok", "apprise_status": status})
            except urllib.error.HTTPError as exc:
                self.json_response(502, {"status": "error", "error": exc.read().decode("utf-8")})
            except Exception as exc:
                self.json_response(500, {"status": "error", "error": str(exc)})

    if __name__ == "__main__":
        threading.Thread(target=poll_alerta, daemon=True).start()
        server = ThreadingHTTPServer((LISTEN_ADDR, LISTEN_PORT), Handler)
        print(f"listening on {LISTEN_ADDR}:{LISTEN_PORT}", flush=True)
        server.serve_forever()
  '';

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
    };

    systemd.services.alerta-bootstrap = {
      description = "Bootstrap Alerta admin user and API key";
      wantedBy = [ "multi-user.target" ];
      after = [ "postgresql.service" ] ++ secretsAfter;
      wants = [ "postgresql.service" ] ++ secretsAfter;
      before = [ "alerta.service" ];
      path = [ pkgs.alerta-server pkgs.coreutils ];
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
        POLL_INTERVAL_SECONDS = "15";
        CLOSED_ALERT_LOOKBACK_SECONDS = "3600";
        STATE_FILE = "/var/lib/alerta-apprise-forwarder/state.json";
      };
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 ${alertaAppriseForwarder}";
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
