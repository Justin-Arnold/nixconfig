{ config, lib, pkgs, inputs, sops-nix, ... }:
let
  hostName = "notifications";
  alertaPort = 5000;
  alertaWebPort = 5001;
  ntfyPort = 8080;
  apprisePort = 8000;
  appriseKey = "homelab-alerts";
  appriseForwarderPort = 9088;
  alertaUrl = "http://${hostName}.host.internal:${toString alertaPort}";
  alertaWebUrl = "http://${hostName}.host.internal:${toString alertaWebPort}";
  ntfyUrl = "http://${hostName}.host.internal:${toString ntfyPort}";

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

  alertaConfig = pkgs.writeText "alertad-notifications.conf" ''
    DATABASE_URL = 'postgresql:///alerta'
    DATABASE_NAME = 'alerta'
    LOG_HANDLERS = ['console']
    LOG_LEVEL = 'INFO'
    BASE_URL = '${alertaUrl}'
    SECRET_KEY = open('${config.sops.secrets."notifications/alerta/secret-key".path}').read().strip()

    AUTH_REQUIRED = True
    AUTH_PROVIDER = 'basic'
    ADMIN_USERS = [open('${config.sops.secrets."notifications/alerta/admin-user".path}').read().strip()]
    SIGNUP_ENABLED = False

    CORS_ORIGINS = [
      'http://localhost',
      'http://localhost:${toString alertaPort}',
      'http://localhost:${toString alertaWebPort}',
      '${alertaUrl}',
      '${alertaWebUrl}',
    ]

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
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    APPRISE_BASE_URL = os.environ.get("APPRISE_BASE_URL", "http://127.0.0.1:${toString apprisePort}")
    APPRISE_KEY = os.environ.get("APPRISE_KEY", "${appriseKey}")
    ALERTA_BASE_URL = os.environ.get("ALERTA_BASE_URL", "http://127.0.0.1:${toString alertaPort}")
    ALERTA_API_KEY_FILE = os.environ.get("ALERTA_API_KEY_FILE")
    LISTEN_ADDR = os.environ.get("LISTEN_ADDR", "127.0.0.1")
    LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "${toString appriseForwarderPort}"))
    POLL_INTERVAL_SECONDS = int(os.environ.get("POLL_INTERVAL_SECONDS", "15"))
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

    def alert_title(alert):
        severity = str(alert.get("severity") or "unknown").upper()
        resource = alert.get("resource") or "unknown-resource"
        event = alert.get("event") or "unknown-event"
        return f"[{severity}] {resource}: {event}"

    def alert_body(alert):
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
        }
        return hashlib.sha256(json.dumps(parts, sort_keys=True).encode("utf-8")).hexdigest()

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
in
{
  imports =
    lib.optional (builtins.pathExists ./hardware-configuration.nix) ./hardware-configuration.nix
    ++ [
      inputs.disko.nixosModules.disko
      ./disko.nix
      ../../modules/common
      ../../modules/profiles/server.nix
      ../../modules/platforms/nixos
      ../../modules/roles/docker.nix

      sops-nix.nixosModules.sops
    ];

  systemProfile = {
    hostname = hostName;
    stateVersion = "25.05";
    isServer = true;
  };

  boot.loader.grub.devices = lib.mkForce [ "/dev/sda" ];

  networking.useDHCP = lib.mkDefault true;

  roles.docker.enable = true;

  sops.age.keyFile = "/home/justin/.config/sops/age/keys.txt";
  sops.defaultSopsFile = ../../secrets/secrets.yaml;

  sops.secrets = {
    "notifications/alerta/secret-key" = {
      owner = "alerta";
      group = "alerta";
      mode = "0400";
    };
    "notifications/alerta/admin-user" = {
      owner = "alerta";
      group = "alerta";
      mode = "0400";
    };
    "notifications/alerta/admin-password" = {
      owner = "alerta";
      group = "alerta";
      mode = "0400";
    };
    "notifications/alerta/api-key" = {
      owner = "alerta";
      group = "alerta";
      mode = "0400";
    };
    "notifications/apprise/config" = {
      owner = "justin";
      group = "users";
      mode = "0400";
    };
    "notifications/ntfy/auth-users" = { };
    "notifications/ntfy/auth-tokens" = { };
  };

  sops.templates."notifications-ntfy.env" = {
    path = "/run/secrets-env/notifications-ntfy.env";
    content = ''
      NTFY_AUTH_USERS='${config.sops.placeholder."notifications/ntfy/auth-users"}'
      NTFY_AUTH_TOKENS='${config.sops.placeholder."notifications/ntfy/auth-tokens"}'
      NTFY_AUTH_ACCESS='apprise:homelab-alerts:write-only'
    '';
    owner = "root";
    group = "root";
    mode = "0400";
  };

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
    bind = "0.0.0.0";
    port = alertaPort;
    databaseUrl = "postgresql:///alerta";
    databaseName = "alerta";
    authenticationRequired = true;
    signupEnabled = false;
    corsOrigins = [
      "http://localhost"
      "http://localhost:${toString alertaPort}"
      "http://localhost:${toString alertaWebPort}"
      alertaUrl
      alertaWebUrl
    ];
  };

  users.users.alerta.group = "alerta";

  systemd.services.alerta = {
    after = [ "network.target" "postgresql.service" "sops-nix.service" "alerta-bootstrap.service" ];
    wants = [ "postgresql.service" "sops-nix.service" ];
    environment.ALERTA_SVR_CONF_FILE = lib.mkForce "${alertaConfig}";
  };

  systemd.services.alerta-bootstrap = {
    description = "Bootstrap Alerta admin user and API key";
    wantedBy = [ "multi-user.target" ];
    after = [ "postgresql.service" "sops-nix.service" ];
    wants = [ "postgresql.service" "sops-nix.service" ];
    before = [ "alerta.service" ];
    path = [ pkgs.alerta-server pkgs.coreutils ];
    environment.ALERTA_SVR_CONF_FILE = "${alertaConfig}";
    script = ''
      admin_user="$(tr -d '\n' < ${config.sops.secrets."notifications/alerta/admin-user".path})"
      admin_password="$(tr -d '\n' < ${config.sops.secrets."notifications/alerta/admin-password".path})"
      api_key="$(tr -d '\n' < ${config.sops.secrets."notifications/alerta/api-key".path})"

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
    environmentFile = config.sops.templates."notifications-ntfy.env".path;
    settings = {
      base-url = ntfyUrl;
      listen-http = "0.0.0.0:${toString ntfyPort}";
      auth-default-access = "deny-all";
      enable-login = true;
    };
  };

  services.nginx = {
    enable = true;
    recommendedGzipSettings = true;
    virtualHosts.alerta-webui = {
      listen = [
        {
          addr = "0.0.0.0";
          port = alertaWebPort;
        }
      ];
      root = alertaWebui;
      locations."/api/".proxyPass = "http://127.0.0.1:${toString alertaPort}/";
      locations."/".tryFiles = "$uri $uri/ /index.html";
    };
  };

  systemd.services.ntfy-sh.preStart = ''
    # ntfy declarative token provisioning is not idempotent against an existing
    # auth DB. Keep users, tokens, and ACLs sourced from SOPS/env on each start.
    rm -f /var/lib/ntfy-sh/user.db
  '';

  systemd.tmpfiles.rules = [
    "d /opt/apprise/config 0750 1000 1000 -"
    "d /opt/apprise/plugin 0750 1000 1000 -"
    "d /opt/apprise/attach 0750 1000 1000 -"
  ];

  virtualisation.oci-containers.containers.apprise = {
    image = "caronc/apprise:latest";
    autoStart = true;
    ports = [ "127.0.0.1:${toString apprisePort}:8000" ];
    volumes = [
      "/opt/apprise/config:/config"
      "/opt/apprise/plugin:/plugin"
      "/opt/apprise/attach:/attach"
      "${config.sops.secrets."notifications/apprise/config".path}:/config/${appriseKey}.cfg:ro"
    ];
    environment = {
      APPRISE_STATEFUL_MODE = "simple";
      APPRISE_WORKER_COUNT = "1";
      APPRISE_ADMIN = "y";
      TZ = "America/New_York";
    };
    extraOptions = [
      "--add-host=notifications.host.internal:host-gateway"
    ];
  };

  systemd.services.docker-apprise = {
    after = [ "sops-nix.service" ];
    wants = [ "sops-nix.service" ];
  };

  systemd.services.alerta-apprise-forwarder = {
    description = "Forward processed Alerta alerts to Apprise API";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" "docker-apprise.service" ];
    wants = [ "docker-apprise.service" ];
    environment = {
      APPRISE_BASE_URL = "http://127.0.0.1:${toString apprisePort}";
      APPRISE_KEY = appriseKey;
      ALERTA_BASE_URL = "http://127.0.0.1:${toString alertaPort}";
      ALERTA_API_KEY_FILE = config.sops.secrets."notifications/alerta/api-key".path;
      LISTEN_ADDR = "127.0.0.1";
      LISTEN_PORT = toString appriseForwarderPort;
      POLL_INTERVAL_SECONDS = "15";
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

  networking.firewall.allowedTCPPorts = [
    alertaPort
    alertaWebPort
    ntfyPort
  ];

  environment.systemPackages = with pkgs; [
    alerta
    curl
    jq
    ntfy-sh
  ];
}
