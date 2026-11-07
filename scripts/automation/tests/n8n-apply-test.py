#!/usr/bin/env python3
"""Runs n8n-apply.py against a fake n8n and a fake sops.

The fake n8n keeps credentials and workflows the way 2.39's public API
does: lists in pages, credentials whose data is never shown, workflows that
are created unpublished, and an X-N8N-API-KEY it checks. The fake sops
answers --decrypt --extract from a JSON file.

Like 2.39, it answers PATCH /credentials/{id} with 405.

It checks that --check needs neither, and refuses workflow files with a
credential's id, an undeclared credential, a literal Authorization header
or a literal secret-named field; that a dry run writes nothing; that
--apply creates the credential from SOPS, the workflow with that
credential's id, and publishes it; that a second run changes nothing; that
drift in n8n is put back with publishIfActive; that a credential deleted in
n8n is made again and the workflow follows it; that what exists only in n8n
is left alone; that a file holding a SOPS value is refused; and that no
secret is ever printed.

usage: n8n-apply-test.py <n8n-apply.py> <hosts/automation>
"""
import copy
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SCRIPT, HOST = sys.argv[1], pathlib.Path(sys.argv[2])
API_KEY = "n8n_api_" + "ab" * 20
SECRETS = {"n8n/api-key": API_KEY, "github/webhook-secret": "whsec-" + "cd" * 16}
PAGE = 2
WORKFLOW_KEYS = {"name", "nodes", "connections", "settings"}


class Fake:
    def __init__(self):
        self.credentials = []
        self.workflows = []
        self.calls = []
        self.made = 0
        self.lock = threading.Lock()

    def page(self, items, query):
        start = int(query.get("cursor", ["0"])[0])
        rest = items[start + PAGE:]
        return {"data": items[start:start + PAGE], "nextCursor": str(start + PAGE) if rest else None}

    def handle(self, method, path, query, body, key):
        if key != API_KEY:
            return 401, {"message": "'X-N8N-API-KEY' header required"}
        self.calls.append((method, path, query, body))
        if path == "/api/v1/credentials" and method == "GET":
            return 200, self.page([{k: c[k] for k in ("id", "name", "type")} for c in self.credentials], query)
        if path == "/api/v1/credentials" and method == "POST":
            self.made += 1
            credential = {"id": f"c{self.made}", **body}
            self.credentials.append(credential)
            return 200, {k: credential[k] for k in ("id", "name", "type")}
        if re.fullmatch(r"/api/v1/credentials/([^/]+)", path) and method == "PATCH":
            return 405, {"message": "PATCH method not allowed"}
        if path == "/api/v1/workflows" and method == "GET":
            return 200, self.page([{k: w[k] for k in ("id", "name", "active", "isArchived")} for w in self.workflows], query)
        if path == "/api/v1/workflows" and method == "POST":
            assert set(body) <= WORKFLOW_KEYS, body
            workflow = {"id": f"w{len(self.workflows) + 1}", "active": False, "isArchived": False, **self.stored(body)}
            self.workflows.append(workflow)
            return 200, workflow
        m = re.fullmatch(r"/api/v1/workflows/([^/]+)(/publish)?", path)
        if m:
            workflow = next(w for w in self.workflows if w["id"] == m[1])
            if method == "GET" and not m[2]:
                return 200, workflow
            if method == "PUT" and not m[2]:
                assert set(body) <= WORKFLOW_KEYS, body
                assert query.get("publishIfActive") == ["true"], query
                workflow.update(self.stored(body))
                return 200, workflow
            if method == "POST" and m[2]:
                workflow["active"] = True
                return 200, workflow
        return 404, {"message": f"no route {method} {path}"}

    @staticmethod
    def stored(body):
        # n8n fills in node fields the repo doesn't set.
        body = copy.deepcopy(body)
        for node in body["nodes"]:
            node.setdefault("disabled", False)
        return body


def serve(fake):
    class Handler(BaseHTTPRequestHandler):
        def _go(self):
            url = urllib.parse.urlsplit(self.path)
            length = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(length)) if length else None
            with fake.lock:
                code, out = fake.handle(self.command, url.path, urllib.parse.parse_qs(url.query), body,
                                        self.headers.get("X-N8N-API-KEY"))
            data = json.dumps(out).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = _go

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


failed = 0


def check(name, ok):
    global failed
    print(("PASS  " if ok else "FAIL  ") + name)
    if not ok:
        failed += 1


tmp = pathlib.Path(tempfile.mkdtemp())
bin_dir = tmp / "bin"
bin_dir.mkdir()
values = tmp / "values.json"
values.write_text(json.dumps(SECRETS))
(bin_dir / "sops").write_text(f"""#!{sys.executable}
import json, re, sys
args = sys.argv[1:]
assert args[:2] == ["--decrypt", "--extract"], args
path = "/".join(re.findall(r'\\["([^"]+)"\\]', args[2]))
values = json.load(open({str(values)!r}))
if path not in values:
    sys.exit(f"[CMD]    ERROR: component {{path}} not found")
print(values[path])
""")
(bin_dir / "sops").chmod(0o755)

fake = Fake()
server = serve(fake)
url = f"http://127.0.0.1:{server.server_port}"
outputs = []


def run(*args, host=HOST, path=True):
    env = {k: v for k, v in os.environ.items() if k != "N8N_API_KEY"}
    env["PATH"] = (f"{bin_dir}:" if path else "") + env.get("PATH", "")
    env["SOPS_AGE_KEY_FILE"] = str(tmp / "keys.txt")
    done = subprocess.run([sys.executable, "-I", SCRIPT, "--url", url, "--host-dir", str(host),
                           "--sops-file", str(tmp / "automation.yaml"), *args],
                          env=env, capture_output=True, text=True)
    outputs.append(done.stdout + done.stderr)
    return done


def host_with(change):
    """A copy of hosts/automation with the github workflow changed."""
    copy_dir = pathlib.Path(tempfile.mkdtemp(dir=tmp))
    shutil.copy(HOST / "n8n-credentials.json", copy_dir)
    (copy_dir / "workflows").mkdir()
    workflow = json.loads((HOST / "workflows/github.json").read_text())
    change(workflow)
    (copy_dir / "workflows/github.json").write_text(json.dumps(workflow))
    return copy_dir


def node(workflow, kind):
    return next(n for n in workflow["nodes"] if n["type"] == kind)


print("== --check needs neither n8n nor sops")
done = run("--check", path=False)
check("exits 0", done.returncode == 0)
check("  ...without calling n8n", fake.calls == [])

print("== --check refuses what could carry a secret")
cases = {
    "a credential's id": lambda w: node(w, "n8n-nodes-base.crypto")["credentials"]["crypto"].update(id="7"),
    "an undeclared credential": lambda w: node(w, "n8n-nodes-base.crypto")["credentials"]["crypto"].update(name="Other"),
    "a literal Authorization header": lambda w: node(w, "n8n-nodes-base.webhook")["parameters"].update(
        headerParameters={"parameters": [{"name": "Authorization", "value": "Bearer x"}]}),
    "a literal secret-named field": lambda w: node(w, "n8n-nodes-base.webhook")["parameters"].update(apiKey="abc"),
}
for what, change in cases.items():
    done = run("--check", host=host_with(change), path=False)
    check(f"refuses {what}", done.returncode != 0 and "refusing" in done.stderr)
done = run("--check", host=host_with(lambda w: node(w, "n8n-nodes-base.webhook")["parameters"].update(
    apiKey="={{ $json.key }}")), path=False)
check("takes an expression in a secret-named field", done.returncode == 0)

print("== dry run")
done = run()
check("exits 0", done.returncode == 0)
check("  ...plans the credential", "+ credential GitHub webhook secret" in done.stdout)
check("  ...and the workflow", "+ workflow github" in done.stdout)
check("  ...writes nothing", all(method == "GET" for method, *_ in fake.calls))

print("== --apply")
done = run("--apply")
check("exits 0", done.returncode == 0)
credential = fake.credentials[0] if fake.credentials else {}
check("creates the credential from SOPS",
      credential.get("type") == "crypto" and credential.get("data") == {"hmacSecret": SECRETS["github/webhook-secret"]})
workflow = fake.workflows[0] if fake.workflows else {"nodes": []}
signer = next((n for n in workflow["nodes"] if n["type"] == "n8n-nodes-base.crypto"), {})
check("creates the workflow with the credential's id",
      signer.get("credentials") == {"crypto": {"id": credential.get("id"), "name": "GitHub webhook secret"}})
check("  ...and publishes it", workflow.get("active") is True)

print("== a second run")
fake.calls.clear()
done = run()
check("dry run: no changes", done.returncode == 0 and "0 change(s) pending" in done.stdout)
check("  ...says how to change the credential", "delete it in n8n and run this again" in done.stdout)
fake.calls.clear()
done = run("--apply")
writes = [(m, p) for m, p, *_ in fake.calls if m != "GET"]
check("--apply writes nothing", done.returncode == 0 and writes == [])

print("== a credential deleted in n8n")
fake.credentials.clear()
done = run("--apply")
remade = fake.credentials[0] if fake.credentials else {}
signer = node(fake.workflows[0], "n8n-nodes-base.crypto")
check("is made again", remade.get("data") == {"hmacSecret": SECRETS["github/webhook-secret"]})
check("  ...and the workflow follows it", signer.get("credentials", {}).get("crypto", {}).get("id") == remade.get("id")
      and remade.get("id") != credential.get("id"))

print("== drift in n8n")
node(fake.workflows[0], "n8n-nodes-base.webhook")["parameters"]["path"] = "elsewhere"
fake.calls.clear()
done = run()
check("dry run names the node and field", "node GitHub delivery parameters" in done.stdout)
done = run("--apply")
check("--apply puts it back", node(fake.workflows[0], "n8n-nodes-base.webhook")["parameters"]["path"] == "github")
check("  ...with publishIfActive", any(m == "PUT" and q.get("publishIfActive") == ["true"] for m, _, q, _ in fake.calls))

print("== what exists only in n8n, or isn't published")
fake.workflows.append({"id": "w9", "name": "by hand", "active": False, "isArchived": False, "nodes": [],
                       "connections": {}, "settings": {}})
fake.credentials.append({"id": "c9", "name": "by hand", "type": "httpHeaderAuth", "data": {}})
fake.workflows[0]["active"] = False
done = run("--apply")
check("reports the workflow", "? workflow by hand exists only in n8n" in done.stdout)
check("  ...and the credential", "? credential by hand exists only in n8n" in done.stdout)
check("  ...deletes neither", len(fake.workflows) == 2 and len(fake.credentials) == 2)
check("publishes the unpublished workflow", fake.workflows[0]["active"] is True)

print("== a workflow file holding a SOPS value")
done = run(host=host_with(lambda w: node(w, "n8n-nodes-base.webhook")["parameters"].update(
    note=SECRETS["github/webhook-secret"])))
check("is refused", done.returncode != 0 and "holds a value from SOPS" in done.stderr)

print("== a wrong API key")
SECRETS["n8n/api-key"] = "wrong"
values.write_text(json.dumps(SECRETS))
done = run()
check("stops with n8n's answer", done.returncode != 0 and "HTTP 401" in done.stderr)

print("== no secret in any output")
check("no SOPS value or API key printed",
      not any(secret in out for out in outputs for secret in (API_KEY, SECRETS["github/webhook-secret"])))

server.shutdown()
print(f"\nfailed: {failed}")
sys.exit(1 if failed else 0)
