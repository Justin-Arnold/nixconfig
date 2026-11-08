#!/usr/bin/env python3
"""Runs n8n-apply.py against a fake n8n and a fake sops.

The fake n8n keeps credentials and workflows the way 2.39's public API
does: lists in pages, credentials whose data is never shown, workflows that
are created unpublished, and an X-N8N-API-KEY it checks. The fake sops
answers --decrypt --extract from a JSON file.

Like 2.39, it answers PATCH /credentials/{id} with 405.

It checks that --check needs neither, and refuses workflow files with a
credential's id, an undeclared credential, a literal Authorization header,
a literal secret-named field, or a SOPS path anywhere but a url and outside
a /url path, and a credentials file with a literal secret; that a dry run
writes nothing; that a credential's literal field is sent as written and a
url marker is filled in from SOPS; that
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
SECRETS = {
    "n8n/api-key": API_KEY,
    "github/webhook-secret": "whsec-" + "cd" * 16,
    "alerta/n8n-key": "alerta-" + "ef" * 16,
    "paperclip-triggers/fix-ci/secret": "pctrig-" + "12" * 16,
    "paperclip-triggers/fix-ci/url": "https://triggers.example/api/routine-triggers/public/" + "0a" * 12 + "/fire",
    "paperclip-triggers/fix-ci-engineer/secret": "pctrig-" + "34" * 16,
    "paperclip-triggers/fix-ci-engineer/url": "https://triggers.example/api/routine-triggers/public/" + "0b" * 12 + "/fire",
}
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


def host_with(change=lambda w: None, change_credentials=lambda c: None):
    """A copy of hosts/automation with the github workflow or the credentials changed."""
    copy_dir = pathlib.Path(tempfile.mkdtemp(dir=tmp))
    credentials = json.loads((HOST / "n8n-credentials.json").read_text())
    change_credentials(credentials)
    (copy_dir / "n8n-credentials.json").write_text(json.dumps(credentials))
    (copy_dir / "workflows").mkdir()
    workflow = json.loads((HOST / "workflows/github.json").read_text())
    change(workflow)
    (copy_dir / "workflows/github.json").write_text(json.dumps(workflow))
    return copy_dir


def node(workflow, kind):
    return next(n for n in workflow["nodes"] if n["type"] == kind)


def named(workflow, name):
    return next(n for n in workflow["nodes"] if n["name"] == name)


def made(name):
    return next((c for c in fake.credentials if c["name"] == name), {})


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
    "a SOPS path in a field that isn't a url": lambda w: node(w, "n8n-nodes-base.webhook")["parameters"].update(
        path={"sops": "paperclip-triggers/fix-ci/url"}),
    "a url from a SOPS path that isn't a /url": lambda w: named(w, "Start Fix CI")["parameters"].update(
        url={"sops": "paperclip-triggers/fix-ci/secret"}),
    "a node type that isn't on the list": lambda w: w["nodes"].append(
        {"id": "x", "name": "Run code", "type": "n8n-nodes-base.code", "typeVersion": 2, "position": [0, 0],
         "parameters": {"jsCode": "return []"}}),
    "a LangChain node": lambda w: w["nodes"].append(
        {"id": "x", "name": "Tool", "type": "@n8n/n8n-nodes-langchain.toolCode", "typeVersion": 1, "position": [0, 0],
         "parameters": {}}),
    "a url built from an expression": lambda w: named(w, "Raise LandReady")["parameters"].update(
        url="={{ 'http://10.118.0.1:5000/alert' }}"),
    "a host that isn't on the list": lambda w: named(w, "Find its pull request")["parameters"].update(
        url="https://example.com/collect"),
    "the Alerta key sent to another listed host": lambda w: named(w, "Raise LandReady")["parameters"].update(
        url="https://api.github.com/gists"),
    "a trigger's secret sent to another trigger": lambda w: named(w, "Start Fix CI")["parameters"].update(
        url={"sops": "paperclip-triggers/other/url"}),
    "a proxy": lambda w: named(w, "Raise LandReady")["parameters"]["options"].update(
        proxy="http://proxy.example:8080"),
    "pagination": lambda w: named(w, "Find its pull request")["parameters"]["options"].update(
        pagination={"pagination": {"nextURL": "={{ $response.body.next }}"}}),
    "the webhook secret in an HTTP node": lambda w: named(w, "Raise LandReady").update(
        credentials={"httpHeaderAuth": {"name": "GitHub webhook secret"}}),
    "a credential on a node that isn't HTTP or Crypto": lambda w: node(w, "n8n-nodes-base.webhook").update(
        credentials={"httpHeaderAuth": {"name": "Alerta key"}}),
    "a predefined credential type": lambda w: named(w, "Raise LandReady")["parameters"].update(
        authentication="predefinedCredentialType", nodeCredentialType="githubApi"),
}

# The part of the refusal that says which rule caught each case.
REASONS = {
    "a credential's id": "gives its crypto credential more than a name",
    "an undeclared credential": "which n8n-credentials.json doesn't declare",
    "a literal Authorization header": "sets an Authorization header itself",
    "a literal secret-named field": "has a literal value for apiKey",
    "a SOPS path in a field that isn't a url": "only a node's url may",
    "a url from a SOPS path that isn't a /url": "isn't a Paperclip trigger's",
    "a node type that isn't on the list": "n8n-nodes-base.code node, which isn't on",
    "a LangChain node": "@n8n/n8n-nodes-langchain.toolCode node, which isn't on",
    "a url built from an expression": "builds its url from an expression",
    "a host that isn't on the list": "calls https://example.com/collect, which isn't on",
    "the Alerta key sent to another listed host": "sends the Alerta key somewhere other than Alerta",
    "a trigger's secret sent to another trigger": "sends the fix-ci trigger's secret somewhere other",
    "a proxy": "sets options.proxy",
    "pagination": "sets options.pagination",
    "the webhook secret in an HTTP node": "uses the webhook secret, which belongs in a Crypto node",
    "a credential on a node that isn't HTTP or Crypto": "only HTTP Request and Crypto nodes may",
    "a predefined credential type": "authenticates with predefinedCredentialType",
}
for what, change in cases.items():
    done = run("--check", host=host_with(change), path=False)
    check(f"refuses {what}", done.returncode != 0 and REASONS[what] in done.stderr)
done = run("--check", host=host_with(lambda w: node(w, "n8n-nodes-base.webhook")["parameters"].update(
    apiKey="={{ $json.key }}")), path=False)
check("takes an expression in a secret-named field", done.returncode == 0)
done = run("--check", host=host_with(change_credentials=lambda c: c["credentials"][1]["data"].update(
    value={"literal": "abc"})), path=False)
check("refuses a literal secret in n8n-credentials.json", done.returncode != 0 and "comes from SOPS" in done.stderr)
done = run("--check", host=host_with(change_credentials=lambda c: c["credentials"][1]["data"].update(
    value="n8n/api-key")), path=False)
check("refuses a credential from a SOPS path that isn't on the list",
      done.returncode != 0 and "isn't on n8n-apply.py's list of what n8n may hold" in done.stderr)
done = run("--check", host=host_with(change_credentials=lambda c: c["credentials"][1]["data"].pop("allowedDomains")),
           path=False)
check("refuses an HTTP credential without its domain fence",
      done.returncode != 0 and 'allowedDomains "10.118.0.1"' in done.stderr)
done = run("--check", host=host_with(change_credentials=lambda c: c["credentials"][2].update(type="httpHeaderAuth")),
           path=False)
check("refuses a trigger's secret in the wrong kind of credential", done.returncode != 0 and "goes in a httpBearerAuth" in done.stderr)

READ_KEY = {"name": "Paperclip read key", "type": "httpBearerAuth",
            "data": {"token": "paperclip/n8n-key", "allowedHttpRequestDomains": {"literal": "domains"},
                     "allowedDomains": {"literal": "paperclip.servicestack.xyz"}}}


def with_read(method):
    def change(w):
        w["nodes"].append({"id": "r", "name": "Open triages", "type": "n8n-nodes-base.httpRequest", "typeVersion": 4.2,
                           "position": [0, 0], "credentials": {"httpBearerAuth": {"name": "Paperclip read key"}},
                           "parameters": {"method": method, "url": {"sops": "paperclip-triggers/triage/open/url"},
                                          "authentication": "genericCredentialType", "genericAuthType": "httpBearerAuth",
                                          "options": {}}})
    return change


done = run("--check", host=host_with(with_read("GET"), lambda c: c["credentials"].append(READ_KEY)), path=False)
check("takes the Paperclip key for a GET of a routine's open issues", done.returncode == 0)
done = run("--check", host=host_with(with_read("POST"), lambda c: c["credentials"].append(READ_KEY)), path=False)
check("refuses the Paperclip key for anything else",
      done.returncode != 0 and "for anything but a GET of a routine's open issues" in done.stderr)

print("== dry run")
done = run()
check("exits 0", done.returncode == 0)
check("  ...plans the credential", "+ credential GitHub webhook secret" in done.stdout)
check("  ...and the workflow", "+ workflow github" in done.stdout)
check("  ...writes nothing", all(method == "GET" for method, *_ in fake.calls))

print("== --apply")
done = run("--apply")
check("exits 0", done.returncode == 0)
credential = made("GitHub webhook secret")
check("creates the credential from SOPS",
      credential.get("type") == "crypto" and credential.get("data") == {"hmacSecret": SECRETS["github/webhook-secret"]})
check("  ...a literal field as written, with the credential's domain fence",
      made("Alerta key").get("data") == {"name": "X-API-Key", "value": SECRETS["alerta/n8n-key"],
                                         "allowedHttpRequestDomains": "domains", "allowedDomains": "10.118.0.1"})
check("  ...and the trigger's bearer token, fenced to the triggers name", made("Paperclip Fix CI trigger").get("data") == {
      "token": SECRETS["paperclip-triggers/fix-ci/secret"], "allowedHttpRequestDomains": "domains",
      "allowedDomains": "paperclip-triggers.servicestack.xyz"})
workflow = fake.workflows[0] if fake.workflows else {"nodes": []}
signer = next((n for n in workflow["nodes"] if n["type"] == "n8n-nodes-base.crypto"), {})
check("creates the workflow with the credential's id",
      signer.get("credentials") == {"crypto": {"id": credential.get("id"), "name": "GitHub webhook secret"}})
check("  ...and publishes it", workflow.get("active") is True)
fire = next((n for n in workflow["nodes"] if n["name"] == "Start Fix CI"), {})
check("fills in the trigger's URL from SOPS", fire.get("parameters", {}).get("url") == SECRETS["paperclip-triggers/fix-ci/url"])

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
remade = made("GitHub webhook secret")
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
declared = len(json.loads((HOST / "n8n-credentials.json").read_text())["credentials"])
check("  ...deletes neither", len(fake.workflows) == 2 and len(fake.credentials) == declared + 1)
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
      not any(secret in out for out in outputs for secret in SECRETS.values()))

server.shutdown()
print(f"\nfailed: {failed}")
sys.exit(1 if failed else 0)
