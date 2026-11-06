#!/usr/bin/env python3
"""Runs forwarder.py against a fake Alerta and a fake Apprise.

It checks that the first pass sends what's open and records an old closed
alert without sending it, that nothing more goes until a kick or the sweep,
that POST /kick makes a pass at once and a kick with nothing new sends
nothing, that a change of status sends again, that a link goes last in the
body, that a pass that couldn't reach Apprise tries again after the retry
with no kick, that the key comes from its file, that state.json keeps what
was sent, and that /healthz and unknown paths answer as before.

usage: forwarder-test.py <forwarder.py>
"""
import importlib.util
import json
import os
import pathlib
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

failures = []


def check(what, ok):
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        failures.append(what)


def iso(when):
    return when.strftime("%Y-%m-%dT%H:%M:%S.000Z")


class Fake:
    def __init__(self):
        self.alerts = []
        self.sent = []
        self.auth = []
        self.apprise_down = False
        self.lock = threading.Lock()


def serve(fake):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def reply(self, status, payload):
            body = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):  # noqa: N802
            if self.path.startswith("/alerts?"):
                with fake.lock:
                    fake.auth.append(self.headers.get("Authorization"))
                    self.reply(200, {"status": "ok", "alerts": list(fake.alerts)})
            elif self.path == "/status":
                self.reply(200, {"status": "ok"})
            else:
                self.reply(404, {})

        def do_POST(self):  # noqa: N802
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
            if self.path == "/notify/homelab-alerts":
                with fake.lock:
                    if fake.apprise_down:
                        self.reply(503, {"error": "down"})
                        return
                    fake.sent.append(body)
                self.reply(200, {})
            else:
                self.reply(404, {})

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def alert(id_, status="open", severity="critical", received=None, **extra):
    return {"id": id_, "resource": f"SVC / {id_}", "event": "http", "severity": severity, "status": status,
            "text": f"Service http is {'up' if severity == 'cleared' else 'down'}.", "environment": "Homelab",
            "lastReceiveTime": iso(received or datetime.now(timezone.utc)), **extra}


def until(what, test, seconds=2.0):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if test():
            return True
        time.sleep(0.02)
    return test()


def post(url):
    request = urllib.request.Request(url, data=b"", method="POST")
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            return response.status
    except urllib.error.HTTPError as err:
        return err.code


def get(url):
    try:
        with urllib.request.urlopen(url, timeout=5) as response:
            return response.status, json.loads(response.read())
    except urllib.error.HTTPError as err:
        return err.code, None


tmp = pathlib.Path(tempfile.mkdtemp())
key_file = tmp / "alerta-key"
key_file.write_text("alerta-key-123\n")
fake = Fake()
fake_server = serve(fake)
fake_url = f"http://127.0.0.1:{fake_server.server_address[1]}"
os.environ.update({
    "APPRISE_BASE_URL": fake_url,
    "ALERTA_BASE_URL": fake_url,
    "ALERTA_API_KEY_FILE": str(key_file),
    "STATE_FILE": str(tmp / "state" / "state.json"),
    "POLL_INTERVAL_SECONDS": "60",
    "RETRY_SECONDS": "0.3",
})
spec = importlib.util.spec_from_file_location("forwarder", sys.argv[1])
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

old = datetime.now(timezone.utc) - timedelta(hours=2)
fake.alerts = [alert("a1"), alert("old", status="closed", severity="cleared", received=old)]
threading.Thread(target=fw.poll_alerta, daemon=True).start()
server = ThreadingHTTPServer(("127.0.0.1", 0), fw.Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
url = f"http://127.0.0.1:{server.server_address[1]}"

check("the first pass sends the open alert", until("first", lambda: len(fake.sent) == 1)
      and fake.sent[0]["title"] == "[CRITICAL] SVC / a1: http" and fake.sent[0]["type"] == "failure")
time.sleep(0.2)
check("a closed alert older than the lookback is recorded, not sent", len(fake.sent) == 1
      and "old" in json.loads((tmp / "state" / "state.json").read_text()))
check("it reads Alerta with the key from its file", fake.auth and set(fake.auth) == {"Key alerta-key-123"})

fake.alerts.append(alert("a2", attributes={"url": "https://paperclip.example/LAB/issues/LAB-1"}))
time.sleep(0.5)
check("a new alert waits for a kick or the sweep", len(fake.sent) == 1)
start = time.monotonic()
check("POST /kick answers 202", post(f"{url}/kick") == 202)
check("a kick sends the new alert at once", until("kicked", lambda: len(fake.sent) == 2, 1.0)
      and time.monotonic() - start < 1.0)
check("a link goes last in the body", fake.sent[-1]["body"].endswith("link: https://paperclip.example/LAB/issues/LAB-1"))

reads = len(fake.auth)
post(f"{url}/kick")
check("a kick with nothing new reads Alerta and sends nothing",
      until("read", lambda: len(fake.auth) > reads) and (time.sleep(0.2) or len(fake.sent) == 2))

fake.alerts[0] = alert("a1", status="ack")
post(f"{url}/kick")
check("a change of status sends again", until("ack", lambda: len(fake.sent) == 3) and fake.sent[-1]["title"].endswith("a1: http"))

with fake.lock:
    fake.apprise_down = True
fake.alerts.append(alert("a3"))
post(f"{url}/kick")
time.sleep(0.15)
with fake.lock:
    fake.apprise_down = False
check("a pass that couldn't reach Apprise tries again after the retry, with no kick",
      until("retry", lambda: len(fake.sent) == 4, 1.5) and fake.sent[-1]["title"] == "[CRITICAL] SVC / a3: http")
time.sleep(0.5)
check("…and sends it only once", len(fake.sent) == 4)

state = json.loads((tmp / "state" / "state.json").read_text())
check("state.json keeps a hash for every alert it has seen", set(state) == {"a1", "a2", "a3", "old"})

status, body = get(f"{url}/healthz")
check("/healthz reports Apprise's status", status == 200 and body == {"status": "ok", "apprise_status": 200})
check("an unknown path is 404", get(f"{url}/nothing")[0] == 404 and post(f"{url}/nothing") == 404)

server.shutdown()
fake_server.shutdown()
if failures:
    sys.exit(f"{len(failures)} check(s) failed")
print("all checks passed")
