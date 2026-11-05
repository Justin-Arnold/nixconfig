#!/usr/bin/env python3
"""Runs paperclip-cancel.py against a fake Paperclip.

The fake signs in like Paperclip 2026.1023.0's CLI sign-in and looks issues
up by identifier at /api/issues/<identifier>, as Paperclip does. It checks
that answering no cancels nothing, that --yes cancels only the open issues,
that an unknown identifier stops the run before anything is cancelled, and
that every run revokes its sign-in key without printing it.

usage: paperclip-cancel-test.py <paperclip-cancel.py>
"""
import json
import os
import re
import subprocess
import sys
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SCRIPT = sys.argv[1]
KEY = "pcp_board_" + "cd" * 24


class Fake:
    def __init__(self):
        self.issues = {
            "LAB-29": {"id": "i29", "identifier": "LAB-29", "title": "Smoke test a: ping", "status": "todo"},
            "LAB-33": {"id": "i33", "identifier": "LAB-33", "title": "Smoke test b: change", "status": "blocked"},
            "LAB-40": {"id": "i40", "identifier": "LAB-40", "title": "Smoke test c: infra", "status": "done"},
            "LAB-41": {"id": "i41", "identifier": "LAB-41", "title": "Smoke test d: gate", "status": "cancelled"},
        }
        self.patches = []
        self.keys = set()
        self.lock = threading.Lock()

    def handle(self, method, path, query, body, auth):
        if method == "POST" and path == "/api/cli-auth/challenges":
            assert body["requestedAccess"] == "board", body
            return 201, {"id": "ch1", "token": "chs", "boardApiToken": KEY, "approvalPath": "/cli-auth/ch1?token=chs",
                         "approvalUrl": None, "pollPath": "/cli-auth/challenges/ch1"}
        if method == "GET" and path == "/api/cli-auth/challenges/ch1":
            assert query.get("token") == ["chs"], query
            self.keys.add(KEY)
            return 200, {"status": "approved"}
        if auth not in self.keys:
            return 401, {"error": "unauthorized"}
        if method == "POST" and path == "/api/cli-auth/revoke-current":
            self.keys.discard(auth)
            return 200, {"revoked": True}
        m = re.fullmatch(r"/api/issues/([^/]+)", path)
        if m:
            issue = self.issues.get(m[1]) or next((i for i in self.issues.values() if i["id"] == m[1]), None)
            if issue is None:
                return 404, {"error": "Issue not found"}
            if method == "GET":
                return 200, issue
            if method == "PATCH":
                assert body == {"status": "cancelled"}, body
                self.patches.append(issue["identifier"])
                issue["status"] = "cancelled"
                return 200, issue
        return 404, {"error": f"no route {method} {path}"}


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

        do_GET = do_POST = do_PATCH = respond

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def run(url, *args, answer=""):
    env = {k: v for k, v in os.environ.items() if k != "PAPERCLIP_BOARD_KEY"}
    proc = subprocess.run([sys.executable, "-I", SCRIPT, "--url", url, *args], input=answer,
                          capture_output=True, text=True, env=env, timeout=60)
    print(proc.stdout + proc.stderr)
    return proc.returncode, proc.stdout + proc.stderr


failures = []


def check(what, ok):
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        failures.append(what)


fake = Fake()
server = serve(fake)
url = f"http://127.0.0.1:{server.server_address[1]}"
outputs = []

code, out = run(url, "LAB-29", "lab-33", "LAB-40", answer="n\n")
outputs.append(out)
check("answering no cancels nothing", code == 0 and fake.patches == [] and "nothing cancelled" in out)
check("it lists each issue with its status", "LAB-29  todo  Smoke test a: ping" in out
      and "LAB-33  blocked" in out and "LAB-40  already done, left alone" in out)
check("it asks about the open ones only", "Cancel 2 issue(s)?" in out)
check("it revokes its key after a no", not fake.keys)

code, out = run(url, "LAB-29", "LAB-99", "--yes")
outputs.append(out)
check("an unknown identifier stops the run", code != 0 and "LAB-99" in out and fake.patches == [])
check("it revokes its key after a failure", not fake.keys)

code, out = run(url, "LAB-29", "LAB-33", "LAB-40", "LAB-41", "LAB-29", "--yes")
outputs.append(out)
check("--yes cancels the open issues once each", code == 0 and fake.patches == ["LAB-29", "LAB-33"])
check("done and cancelled issues are left alone",
      fake.issues["LAB-40"]["status"] == "done" and "LAB-41  already cancelled, left alone" in out)
check("it revokes its key after cancelling", not fake.keys)

code, out = run(url, "LAB-29", "LAB-33", "--yes")
outputs.append(out)
check("a second run finds nothing to cancel", code == 0 and "nothing to cancel" in out and len(fake.patches) == 2)

code, out = run(url, "rm -rf", "--yes")
outputs.append(out)
check("a malformed identifier is refused before signing in", code != 0 and "not an issue identifier" in out
      and "Approve this sign-in" not in out)

check("the board key is never printed", all(KEY not in o for o in outputs))

server.shutdown()
if failures:
    sys.exit(f"{len(failures)} check(s) failed")
print("all checks passed")
