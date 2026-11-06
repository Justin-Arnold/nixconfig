#!/usr/bin/env python3
"""Runs paperclip-agent-key.py against a fake Paperclip and a fake sops.

The fake Paperclip signs in like 2026.1023.0's CLI sign-in, lists the LAB
company and its agents, and keeps named keys on each agent at
/api/agents/<id>/keys. The fake sops records its arguments and what came on
stdin, and fails when told to. It checks that the paperclip-events key is
made on the Researcher with no scope and goes to SOPS on stdin as JSON at
paperclip-events/paperclip-key, that a failed sops revokes it, that older
keys are left until --revoke-old, which keeps only the newest, that another
agent's keys are never touched, that an unknown service is refused before
it signs in, and that no key is ever printed.

usage: paperclip-agent-key-test.py <paperclip-agent-key.py>
"""
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SCRIPT = sys.argv[1]
SIGN_IN = "pcp_board_" + "cd" * 24
COMPANY = "c0000000-0000-4000-8000-000000000001"
RESEARCHER = "a0000000-0000-4000-8000-000000000002"
MONITOR = "a0000000-0000-4000-8000-000000000003"


class Fake:
    def __init__(self):
        self.signed_in = set()
        self.keys = []
        self.made = 0
        self.lock = threading.Lock()
        # Another agent's key with the same name, which must be left alone.
        self.keys.append({"id": "m1", "agentId": MONITOR, "name": "paperclip-events", "token": "pcp_" + "ee" * 24,
                          "createdAt": "2026-11-01T00:00:00Z", "revokedAt": None})

    def handle(self, method, path, query, body, auth):
        if method == "POST" and path == "/api/cli-auth/challenges":
            assert body["requestedAccess"] == "board", body
            return 201, {"id": "ch1", "token": "chs", "boardApiToken": SIGN_IN, "approvalPath": "/cli-auth/ch1?token=chs",
                         "approvalUrl": None, "pollPath": "/cli-auth/challenges/ch1"}
        if method == "GET" and path == "/api/cli-auth/challenges/ch1":
            self.signed_in.add(SIGN_IN)
            return 200, {"status": "approved"}
        if auth not in self.signed_in:
            return 401, {"error": "unauthorized"}
        if method == "POST" and path == "/api/cli-auth/revoke-current":
            self.signed_in.discard(auth)
            return 200, {"revoked": True}
        if method == "GET" and path == "/api/companies":
            return 200, [{"id": "other", "issuePrefix": "XYZ"}, {"id": COMPANY, "issuePrefix": "LAB"}]
        if method == "GET" and path == f"/api/companies/{COMPANY}/agents":
            return 200, [{"id": MONITOR, "name": "Monitor"}, {"id": RESEARCHER, "name": "Researcher"}]
        m = re.fullmatch(r"/api/agents/([^/]+)/keys", path)
        if m and method == "GET":
            return 200, [{k: v for k, v in key.items() if k not in ("token", "agentId")}
                         for key in self.keys if key["agentId"] == m[1] and not key["revokedAt"]]
        if m and method == "POST":
            assert m[1] == RESEARCHER, m[1]
            assert body == {"name": "paperclip-events"}, body
            self.made += 1
            key = {"id": f"k{self.made}", "agentId": m[1], "name": body["name"], "token": "pcp_" + f"{self.made:02d}" * 24,
                   "createdAt": f"2026-11-06T00:00:{self.made:02d}Z", "revokedAt": None}
            self.keys.append(key)
            return 201, {k: v for k, v in key.items() if k != "agentId"}
        m = re.fullmatch(r"/api/agents/([^/]+)/keys/([^/]+)", path)
        if m and method == "DELETE":
            key = next((k for k in self.keys if k["id"] == m[2] and k["agentId"] == m[1]), None)
            if key is None:
                return 404, {"error": "Key not found"}
            key["revokedAt"] = "now"
            return 200, {"ok": True}
        return 404, {"error": f"no route {method} {path}"}

    def active(self, agent=RESEARCHER):
        return [k["id"] for k in self.keys if not k["revokedAt"] and k["agentId"] == agent]


def serve(fake):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def respond(self):
            url = urllib.parse.urlsplit(self.path)
            length = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(length)) if length else None
            auth = (self.headers.get("Authorization") or "").removeprefix("Bearer ")
            with fake.lock:
                try:
                    status, out = fake.handle(self.command, url.path, urllib.parse.parse_qs(url.query), body, auth)
                except AssertionError as err:
                    status, out = 500, {"error": f"fake refused: {err}"}
            data = json.dumps(out).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        do_GET = do_POST = do_DELETE = respond

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


tmp = pathlib.Path(tempfile.mkdtemp())
bin_dir = tmp / "bin"
bin_dir.mkdir()
record = tmp / "sops.json"
(bin_dir / "sops").write_text(f"""#!{sys.executable}
import json, os, sys
json.dump({{"args": sys.argv[1:], "stdin": sys.stdin.read(), "age": os.environ.get("SOPS_AGE_KEY_FILE")}},
          open({str(record)!r}, "w"))
if os.environ.get("FAKE_SOPS_FAIL"):
    sys.exit("sops: could not decrypt the data key")
""")
(bin_dir / "sops").chmod(0o755)
age_key = tmp / "keys.txt"
age_key.write_text("AGE-SECRET-KEY-1EXAMPLE\n")


def run(url, *args, fail=False, age=str(age_key)):
    env = {**os.environ, "PATH": f"{bin_dir}:{os.environ.get('PATH', '')}", "SOPS_AGE_KEY_FILE": age}
    env.pop("FAKE_SOPS_FAIL", None)
    if fail:
        env["FAKE_SOPS_FAIL"] = "1"
    record.unlink(missing_ok=True)
    proc = subprocess.run([sys.executable, "-I", SCRIPT, *args, "--url", url],
                          capture_output=True, text=True, env=env, timeout=60)
    print(proc.stdout + proc.stderr)
    sops = json.loads(record.read_text()) if record.exists() else None
    return proc.returncode, proc.stdout + proc.stderr, sops


failures = []


def check(what, ok):
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        failures.append(what)


fake = Fake()
server = serve(fake)
url = f"http://127.0.0.1:{server.server_address[1]}"
outputs = []

code, out, sops = run(url, "paperclip-events")
outputs.append(out)
first = next(k for k in fake.keys if k["id"] == "k1")
check("it makes a paperclip-events key on the Researcher and keeps it", code == 0 and fake.active() == ["k1"])
check("the key goes to sops set on stdin, JSON-encoded, at paperclip-events/paperclip-key in agents.yaml",
      sops is not None and sops["args"][:2] == ["set", "--value-stdin"]
      and sops["args"][2].endswith("secrets/hosts/agents.yaml") and sops["args"][3] == '["paperclip-events"]["paperclip-key"]'
      and json.loads(sops["stdin"]) == first["token"] and sops["age"] == str(age_key))
check("it says where the key went", "at paperclip-events/paperclip-key" in out)
check("it revokes its sign-in key", not fake.signed_in)

code, out, sops = run(url, "paperclip-events", fail=True)
outputs.append(out)
check("when sops fails, the new key is revoked and the run fails",
      code != 0 and "sops couldn't set" in out and fake.active() == ["k1"]
      and next(k for k in fake.keys if k["id"] == "k2")["revokedAt"])
check("it revokes its sign-in key after a failure", not fake.signed_in)

code, out, sops = run(url, "paperclip-events")
outputs.append(out)
check("an older key keeps working, and it says so", code == 0 and fake.active() == ["k1", "k3"]
      and "1 older paperclip-events key(s) still work" in out)

code, out, sops = run(url, "paperclip-events", "--revoke-old")
outputs.append(out)
check("--revoke-old keeps only the newest and makes no key", code == 0 and fake.active() == ["k3"]
      and sops is None and fake.made == 3)
check("another agent's key of the same name is never touched", fake.active(MONITOR) == ["m1"])

code, out, sops = run(url, "something-else")
outputs.append(out)
check("an unknown service is refused before it signs in", code != 0 and "invalid choice" in out
      and "Approve this sign-in" not in out and fake.made == 3)

code, out, sops = run(url, "paperclip-events", age=str(tmp / "missing.txt"))
outputs.append(out)
check("a missing age key stops the run before it signs in", code != 0 and "no age key" in out
      and "Approve this sign-in" not in out and fake.made == 3)

check("no key is ever printed", all(k["token"] not in o and SIGN_IN not in o for k in fake.keys for o in outputs))

server.shutdown()
if failures:
    sys.exit(f"{len(failures)} check(s) failed")
print("all checks passed")
