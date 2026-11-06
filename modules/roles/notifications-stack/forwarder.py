#!/usr/bin/env python3
"""alerta-apprise-forwarder: Alerta's alerts onto the phone, through Apprise.

A long-running service in the notifications-stack role. It reads Alerta's
open, acknowledged and closed alerts whenever Alerta's push plugin POSTs
/kick, which it does as an alert comes in or changes, and every
POLL_INTERVAL_SECONDS anyway. A pass that went wrong, say with Apprise or
Alerta down, tries again after RETRY_SECONDS, since no kick may come to say
they're back.

For each alert it hashes the id, severity, status, text and any custom title
or body, and compares that with STATE_FILE. A new hash is sent to Apprise,
logged as "sent <id>: <title>", and recorded. A closed alert that hasn't changed for
CLOSED_ALERT_LOOKBACK_SECONDS is recorded without sending, which is what
stops a flood after a restart or a restore.

It also serves, on LISTEN_ADDR:LISTEN_PORT, GET /healthz (Apprise's status)
and POST /alert, which sends the alert in the body straight to Apprise.
"""
import hashlib
import json
import os
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

APPRISE_BASE_URL = os.environ.get("APPRISE_BASE_URL", "http://127.0.0.1:8000")
APPRISE_KEY = os.environ.get("APPRISE_KEY", "homelab-alerts")
ALERTA_BASE_URL = os.environ.get("ALERTA_BASE_URL", "http://127.0.0.1:5000")
ALERTA_API_KEY_FILE = os.environ.get("ALERTA_API_KEY_FILE")
LISTEN_ADDR = os.environ.get("LISTEN_ADDR", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "9088"))
POLL_INTERVAL_SECONDS = float(os.environ.get("POLL_INTERVAL_SECONDS", "300"))
RETRY_SECONDS = float(os.environ.get("RETRY_SECONDS", "15"))
CLOSED_ALERT_LOOKBACK_SECONDS = int(os.environ.get("CLOSED_ALERT_LOOKBACK_SECONDS", "3600"))
STATE_FILE = os.environ.get("STATE_FILE", "/var/lib/alerta-apprise-forwarder/state.json")

# Set by POST /kick. A kick during a pass makes one more pass.
WAKE = threading.Event()

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
    # A link to what the alert is about (agent-watch sets one for an
    # issue or approval) goes last; ntfy makes it tappable.
    link = attributes.get("url")
    if attributes.get("notificationBody"):
        body = str(attributes["notificationBody"])
        return f"{body}\n{link}" if link else body
    fields = [
        ("text", alert.get("text")),
        ("service", ", ".join(alert.get("service") or [])),
        ("environment", alert.get("environment")),
        ("group", alert.get("group")),
        ("origin", alert.get("origin")),
        ("value", alert.get("value")),
        ("tags", ", ".join(alert.get("tags") or [])),
        ("id", alert.get("id")),
        ("link", link),
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


def forward_once(state):
    changed = False
    try:
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
            print(f"sent {alert_id}: {alert_title(alert)}", flush=True)
            state[alert_id] = fingerprint
            changed = True
    finally:
        if changed:
            save_state(state)


def poll_alerta():
    state = load_state()
    while True:
        WAKE.clear()
        try:
            forward_once(state)
            wait = POLL_INTERVAL_SECONDS
        except Exception as exc:
            print(f"poll failed: {exc}", file=sys.stderr)
            wait = min(POLL_INTERVAL_SECONDS, RETRY_SECONDS)
        WAKE.wait(wait)


def apprise_health():
    request = urllib.request.Request(f"{APPRISE_BASE_URL}/status", method="GET")
    with urllib.request.urlopen(request, timeout=5) as response:
        response.read()
        return response.status


class Handler(BaseHTTPRequestHandler):
    server_version = "alerta-apprise-forwarder/1.0"

    def log_message(self, fmt, *args):
        # A kick comes with every alert Alerta takes in, repeats included.
        if self.path == "/kick":
            return
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
        length = int(self.headers.get("Content-Length") or "0")
        if self.path == "/kick":
            self.rfile.read(length)
            WAKE.set()
            self.json_response(202, {"status": "ok"})
            return
        if self.path != "/alert":
            self.json_response(404, {"status": "not_found"})
            return

        try:
            alert = json.loads(self.rfile.read(length).decode("utf-8"))
            status = notify_apprise(alert)
            self.json_response(200, {"status": "ok", "apprise_status": status})
        except urllib.error.HTTPError as exc:
            self.json_response(502, {"status": "error", "error": exc.read().decode("utf-8")})
        except Exception as exc:
            self.json_response(500, {"status": "error", "error": str(exc)})


def main():
    threading.Thread(target=poll_alerta, daemon=True).start()
    server = ThreadingHTTPServer((LISTEN_ADDR, LISTEN_PORT), Handler)
    print(f"listening on {LISTEN_ADDR}:{LISTEN_PORT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
