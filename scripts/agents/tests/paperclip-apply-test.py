#!/usr/bin/env python3
"""Runs paperclip-apply.py against a fake Paperclip.

The fake keeps the rules the script depends on in Paperclip 2026.1023.0:
board keys from the CLI sign-in, adapterConfig merged over what's stored with
secrets redacted on the way out, runtimeConfig replaced whole, labels that
can't be changed, hires that wait for approval when the company says so, and
routines whose variables are rebuilt from the {{placeholders}} in their title
and description.
It checks a dry run changes nothing, --apply makes exactly the expected
changes, and a second run finds nothing to do.

usage: paperclip-apply-test.py <paperclip-apply.py>
"""
import copy
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
CID = "c0000000-0000-4000-8000-000000000001"
KEY = "pcp_board_" + "ab" * 24

PATHS = {
    "/api/cli-auth/challenges": ["post"],
    "/api/cli-auth/challenges/{id}": ["get"],
    "/api/cli-auth/revoke-current": ["post"],
    "/api/companies": ["get", "post"],
    "/api/companies/{companyId}": ["get", "patch", "delete"],
    "/api/companies/{companyId}/labels": ["get", "post"],
    "/api/companies/{companyId}/secrets": ["get", "post"],
    "/api/companies/{companyId}/agents": ["get", "post"],
    "/api/companies/{companyId}/agent-hires": ["post"],
    "/api/agents/{id}": ["get", "patch", "delete"],
    "/api/agents/{id}/permissions": ["patch"],
    "/api/agents/{id}/approve": ["post"],
    "/api/companies/{companyId}/routines": ["get", "post"],
    "/api/routines/{id}": ["get", "patch"],
    "/api/routines/{id}/triggers": ["post"],
    "/api/routine-triggers/{id}": ["patch", "delete"],
}

# Built into Paperclip's routine templates, so never variables.
BUILTIN = {"date", "timestamp", "workspaceBranch"}
VARIABLE = {"label": None, "type": "text", "defaultValue": None, "required": True, "options": []}


def rebuild(title, description, declared):
    """packages/shared/src/routine-variables.ts: one variable per placeholder, declared ones kept."""
    names = []
    for name in re.findall(r"\{\{\s*([A-Za-z][A-Za-z0-9_]*)\s*\}\}", f"{title}\n{description or ''}"):
        if name not in BUILTIN and name not in names:
            names.append(name)
    by_name = {v["name"]: v for v in declared or []}
    return [{**VARIABLE, **by_name.get(name, {}), "name": name} for name in names]


def routine_row(r):
    return {k: v for k, v in r.items()}


# server/src/redaction.ts: a key is secret when its name ends in one of these.
SECRET_KEY = re.compile(
    r"^(?:[A-Za-z0-9_-]*(?:api[-_]?key|access[-_]?token|auth(?:_?token)?|token|authorization(?:[-_]?code)?|bearer"
    r"|secrets?|passwd|passwords?|credentials?|jwt|private[-_]?key|cookie|connectionstring|browser[-_]?code"
    r"|login[-_]?url)(?:[-_]?(?:value|header|prod(?:uction)?|dev(?:elopment)?|test|staging|primary|secondary))*)"
    r"(?:_plain|_ref)?$", re.I)


def redact(record):
    out = {}
    for k, v in record.items():
        if isinstance(v, dict) and v.get("type") == "secret_ref":
            out[k] = v
        elif SECRET_KEY.match(k):
            out[k] = "***REDACTED***"
        elif isinstance(v, dict):
            out[k] = redact(v)
        else:
            out[k] = v
    return out


def hermes(port, secret):
    return {"apiBaseUrl": f"http://127.0.0.1:{port}", "apiKey": {"type": "secret_ref", "secretId": secret, "version": "latest"}}


def initial_state():
    return {
        "company": {"id": CID, "name": "Lab", "issuePrefix": "LAB", "requireBoardApprovalForNewAgents": False},
        "labels": [
            {"id": "l1", "name": "change", "color": "#000000"},
            {"id": "l2", "name": "bug", "color": "#00ff00"},
        ],
        "secrets": [
            {"id": "s1", "name": "coordinator-api-key"},
            {"id": "s2", "name": "engineer-api-key"},
            {"id": "s3", "name": "researcher-api-key"},
            {"id": "s4", "name": "reviewer-api-key"},
        ],
        "agents": [
            {"id": "a1", "name": "Coordinator", "role": "ceo", "reportsTo": None, "status": "idle",
             "adapterType": "hermes_gateway", "adapterConfig": {**hermes(8642, "s1"), "sessionKeyStrategy": "issue"},
             "runtimeConfig": {"heartbeat": {"enabled": False}}, "permissions": {"canCreateAgents": False}},
            # Drift: role, manager, session strategy, a timer, may create agents.
            {"id": "a2", "name": "Engineer", "role": "general", "reportsTo": None, "status": "idle",
             "adapterType": "hermes_gateway", "adapterConfig": hermes(8643, "s2"),
             "runtimeConfig": {"heartbeat": {"enabled": True, "intervalSec": 3600, "maxConcurrentRuns": 2}, "keep": 1},
             "permissions": {"canCreateAgents": True}},
            {"id": "a3", "name": "Researcher", "role": "researcher", "reportsTo": "a1", "status": "idle",
             "adapterType": "hermes_gateway", "adapterConfig": {**hermes(8644, "s3"), "sessionKeyStrategy": "issue"},
             "runtimeConfig": {}, "permissions": {}},
            # The concierge's settings hold its gateway token, so they're only reported.
            {"id": "a4", "name": "Concierge", "role": "general", "reportsTo": "a1", "status": "idle",
             "adapterType": "openclaw_gateway",
             "adapterConfig": {"url": "wss://old.example", "headers": {"x-openclaw-token": "real-token"}},
             "runtimeConfig": {}, "permissions": {}},
            {"id": "a5", "name": "Old", "role": "general", "reportsTo": None, "status": "terminated",
             "adapterType": "process", "adapterConfig": {}, "runtimeConfig": {}, "permissions": {}},
            {"id": "a6", "name": "Scratch", "role": "general", "reportsTo": None, "status": "idle",
             "adapterType": "process", "adapterConfig": {}, "runtimeConfig": {}, "permissions": {}},
        ],
        "routines": [
            {"id": "r1", "title": "Lab health review {{date}}", "description": "Old instructions.", "assigneeAgentId": "a1",
             "priority": "low", "status": "active", "concurrencyPolicy": "coalesce_if_active",
             "catchUpPolicy": "skip_missed", "variables": []},
            {"id": "r2", "title": "Scratch routine", "description": None, "assigneeAgentId": "a3", "priority": "medium",
             "status": "paused", "concurrencyPolicy": "coalesce_if_active", "catchUpPolicy": "skip_missed",
             "variables": []},
            {"id": "r3", "title": "Gone", "description": None, "assigneeAgentId": "a3", "priority": "medium",
             "status": "archived", "concurrencyPolicy": "coalesce_if_active", "catchUpPolicy": "skip_missed",
             "variables": []},
        ],
        "triggers": [
            {"id": "t1", "routineId": "r1", "kind": "schedule", "label": "every morning", "enabled": True,
             "cronExpression": "0 6 * * *", "timezone": "UTC"},
            {"id": "t2", "routineId": "r1", "kind": "webhook", "label": "old hook", "enabled": True,
             "cronExpression": None, "timezone": None},
        ],
    }


DESCRIPTIONS = {
    "routines/health.md": "Check the lab on {{date}}.\n",
    "routines/review.md": "Review pull request {{number}} in {{repo}}.\n",
}


SPEC = {
    "company": {"issuePrefix": "LAB", "requireBoardApprovalForNewAgents": True},
    "labels": [{"name": "change", "color": "#d97706"}, {"name": "sensitive", "color": "#dc2626"}],
    "agents": [
        {"name": "Coordinator", "role": "ceo", "reportsTo": None, "adapterType": "hermes_gateway",
         "adapterConfig": {"apiBaseUrl": "http://127.0.0.1:8642", "sessionKeyStrategy": "issue"},
         "heartbeat": {"enabled": False, "wakeOnDemand": True}, "canCreateAgents": False},
        {"name": "Engineer", "role": "engineer", "reportsTo": "Coordinator", "adapterType": "hermes_gateway",
         "adapterConfig": {"apiBaseUrl": "http://127.0.0.1:8643", "sessionKeyStrategy": "issue"},
         "heartbeat": {"enabled": False, "wakeOnDemand": True}, "canCreateAgents": False},
        {"name": "Researcher", "role": "researcher", "reportsTo": "Coordinator", "adapterType": "hermes_gateway",
         "adapterConfig": {"apiBaseUrl": "http://127.0.0.1:8644", "sessionKeyStrategy": "issue"},
         "apiKeySecret": "researcher-api-key", "canCreateAgents": False},
        {"name": "Concierge", "role": "general", "reportsTo": "Coordinator", "adapterType": "openclaw_gateway",
         "adapterConfig": {"url": "wss://openclaw.servicestack.xyz"},
         "heartbeat": {"enabled": False, "wakeOnDemand": True}, "canCreateAgents": False},
        {"name": "Reviewer", "role": "qa", "title": "Reviews pull requests", "reportsTo": "Coordinator",
         "adapterType": "hermes_gateway", "apiKeySecret": "reviewer-api-key",
         "adapterConfig": {"apiBaseUrl": "http://127.0.0.1:8645", "sessionKeyStrategy": "issue"},
         "heartbeat": {"enabled": False, "wakeOnDemand": True}, "canCreateAgents": False},
        {"name": "Watcher", "role": "general", "reportsTo": "Coordinator", "adapterType": "hermes_gateway",
         "apiKeySecret": "no-such-secret", "adapterConfig": {"apiBaseUrl": "http://127.0.0.1:8646"}},
    ],
    "routines": [
        {"title": "Lab health review {{date}}", "assignee": "Researcher", "descriptionFile": "routines/health.md",
         "priority": "medium", "concurrencyPolicy": "skip_if_active", "catchUpPolicy": "skip_missed",
         "triggers": [{"label": "every morning", "kind": "schedule", "cronExpression": "0 7 * * *",
                       "timezone": "America/New_York"}]},
        # Its assignee is hired in the same run.
        {"title": "Review {{repo}}#{{number}}", "assignee": "Reviewer", "descriptionFile": "routines/review.md",
         "priority": "medium", "concurrencyPolicy": "always_enqueue", "catchUpPolicy": "skip_missed",
         "variables": [{"name": "repo", "label": "Repository", "type": "select", "options": ["nixconfig", "agent-scratch"]},
                       {"name": "number", "label": "Pull request", "type": "number"}],
         "triggers": []},
    ],
}


class Fake:
    def __init__(self):
        self.state = initial_state()
        self.writes = []
        self.keys = set()
        self.challenges = {}
        self.lock = threading.Lock()

    def redact(self, agent):
        out = copy.deepcopy(agent)
        out["adapterConfig"] = redact(out["adapterConfig"])
        return out

    def agent(self, aid):
        return next(a for a in self.state["agents"] if a["id"] == aid)

    def handle(self, method, path, query, body, auth):
        if path == "/api/openapi.json":
            return 200, {"paths": {p: {m: {} for m in ms} for p, ms in PATHS.items()}}
        if method == "POST" and path == "/api/cli-auth/challenges":
            assert body["requestedAccess"] == "board", body
            self.challenges["ch1"] = {"secret": "chs", "polls": 0}
            return 201, {"id": "ch1", "token": "chs", "boardApiToken": KEY, "approvalPath": "/cli-auth/ch1?token=chs",
                         "approvalUrl": None, "pollPath": "/cli-auth/challenges/ch1"}
        m = re.fullmatch(r"/api/cli-auth/challenges/(\w+)", path)
        if method == "GET" and m:
            ch = self.challenges[m[1]]
            assert query.get("token") == [ch["secret"]], query
            ch["polls"] += 1
            if ch["polls"] < 2:
                return 200, {"status": "pending"}
            self.keys.add(KEY)
            return 200, {"status": "approved"}

        if auth not in self.keys:
            return 401, {"error": "Board authentication required"}
        if method == "POST" and path == "/api/cli-auth/revoke-current":
            self.keys.discard(auth)
            return 200, {"revoked": True}

        if method != "GET":
            self.writes.append((method, path, body))
        company = self.state["company"]
        if method == "GET" and path == "/api/companies":
            return 200, [{k: company[k] for k in ("id", "name", "issuePrefix")}]
        if path == f"/api/companies/{CID}":
            if method == "PATCH":
                company.update(body)
            return 200, company
        if path == f"/api/companies/{CID}/labels":
            if method == "POST":
                label = {"id": f"l{len(self.state['labels']) + 1}", **body}
                self.state["labels"].append(label)
                return 201, label
            return 200, self.state["labels"]
        if method == "GET" and path == f"/api/companies/{CID}/secrets":
            return 200, self.state["secrets"]
        if method == "GET" and path == f"/api/companies/{CID}/agents":
            return 200, [self.redact(a) for a in self.state["agents"]]
        if method == "POST" and path == f"/api/companies/{CID}/agent-hires":
            agent = {"id": f"a{len(self.state['agents']) + 1}", "status": "pending_approval" if company["requireBoardApprovalForNewAgents"] else "idle", **body}
            self.state["agents"].append(agent)
            return 201, {"agent": self.redact(agent), "approval": {"id": "ap1"}}
        m = re.fullmatch(r"/api/agents/(\w+)(/permissions|/approve)?", path)
        if m:
            agent = self.agent(m[1])
            if m[2] == "/approve":
                assert agent["status"] == "pending_approval"
                agent["status"] = "idle"
            elif m[2] == "/permissions":
                assert set(body) == {"canCreateAgents", "canAssignTasks"}, body
                agent["permissions"] = {**agent["permissions"], "canCreateAgents": body["canCreateAgents"]}
            else:
                assert "REDACTED" not in json.dumps(body), body
                if "adapterConfig" in body:
                    agent["adapterConfig"] = {**agent["adapterConfig"], **body["adapterConfig"]}
                for k, v in body.items():
                    if k != "adapterConfig":
                        agent[k] = v
            return 200, self.redact(agent)

        routines = self.state["routines"]
        triggers = self.state["triggers"]
        if path == f"/api/companies/{CID}/routines":
            if method == "POST":
                assert set(body) <= {"title", "description", "assigneeAgentId", "status", "variables", "priority",
                                     "concurrencyPolicy", "catchUpPolicy"}, body
                routine = {"id": f"r{len(routines) + 1}", "priority": "medium", "concurrencyPolicy": "coalesce_if_active",
                           "catchUpPolicy": "skip_missed", **body}
                # Without an assignee Paperclip saves an active routine as paused.
                if not routine.get("assigneeAgentId"):
                    routine["status"] = "paused"
                routine["variables"] = rebuild(routine["title"], routine.get("description"), body.get("variables"))
                routines.append(routine)
                return 201, routine
            return 200, [{**r, "triggers": [{k: t[k] for k in ("id", "kind", "label", "enabled", "cronExpression", "timezone")}
                                            for t in triggers if t["routineId"] == r["id"]]} for r in routines]
        m = re.fullmatch(r"/api/routines/(\w+)(/triggers)?", path)
        if m:
            routine = next(r for r in routines if r["id"] == m[1])
            if m[2]:
                assert method == "POST" and body["kind"] != "webhook", body
                trigger = {"id": f"t{len(triggers) + 1}", "routineId": routine["id"], "cronExpression": None,
                           "timezone": None, **body}
                triggers.append(trigger)
                return 201, {"trigger": trigger, "secretMaterial": None, "revision": {"id": "rev"}}
            if method == "PATCH":
                assert routine["status"] != "archived"
                routine.update(body)
                routine["variables"] = rebuild(routine["title"], routine.get("description"),
                                               body.get("variables", routine["variables"]))
            return 200, routine
        m = re.fullmatch(r"/api/routine-triggers/(\w+)", path)
        if m and method == "PATCH":
            trigger = next(t for t in triggers if t["id"] == m[1])
            assert set(body) <= {"enabled", "cronExpression", "timezone", "label"}, body
            trigger.update(body)
            return 200, trigger
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


def run(url, spec_path, *extra):
    env = {k: v for k, v in os.environ.items() if k != "PAPERCLIP_BOARD_KEY"}
    proc = subprocess.run([sys.executable, "-I", SCRIPT, "--url", url, "--spec", spec_path, *extra],
                          capture_output=True, text=True, env=env, timeout=60)
    print(proc.stdout + proc.stderr)
    if proc.returncode != 0:
        sys.exit(f"FAIL: exit {proc.returncode}")
    return proc.stdout


failures = []


def check(what, ok):
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        failures.append(what)


fake = Fake()
server = serve(fake)
url = f"http://127.0.0.1:{server.server_address[1]}"
spec_path = pathlib.Path(tempfile.mkdtemp()) / "spec.json"
spec_path.write_text(json.dumps(SPEC))
for name, text in DESCRIPTIONS.items():
    (spec_path.parent / name).parent.mkdir(exist_ok=True)
    (spec_path.parent / name).write_text(text)

out = run(url, str(spec_path))
check("dry run writes nothing", fake.writes == [])
check("dry run revokes its sign-in key", not fake.keys)
check("dry run reports the company setting", "~ company Lab: requireBoardApprovalForNewAgents false -> true" in out)
check("dry run reports the label colour it can't change", "! label change is #000000" in out)
check("dry run reports labels and agents only in Paperclip", "? label bug" in out and "? agent Scratch" in out)
check("terminated agents are ignored", "Old" not in out)
check("dry run plans the hire", "+ agent Reviewer (qa, http://127.0.0.1:8645, key from secret reviewer-api-key" in out)
check("an agent without its secret isn't hired", "! agent Watcher is missing and can't be hired" in out)
check("the concierge's adapter drift is only reported", "! agent Concierge: url is wss://old.example" in out)
check("an agent's secret is checked by name", "= agent Researcher (key from secret researcher-api-key)" in out)
check("dry run plans the routine drift", "~ routine Lab health review {{date}}: description, assignee Coordinator -> "
      "Researcher, priority low -> medium, concurrencyPolicy coalesce_if_active -> skip_if_active, trigger every "
      "morning cronExpression 0 6 * * * -> 0 7 * * *, trigger every morning timezone UTC -> America/New_York" in out)
check("dry run plans the new routine", "+ routine Review {{repo}}#{{number}} (for Reviewer, no triggers)" in out)
check("dry run reports a webhook trigger it found",
      "! routine Lab health review {{date}}: webhook trigger old hook exists in Paperclip" in out)
check("dry run reports routines only in Paperclip, but not archived ones",
      "? routine Scratch routine exists only in Paperclip" in out and "Gone" not in out)
check("dry run counts its changes", "6 change(s) pending" in out)

out = run(url, str(spec_path), "--apply")
state = fake.state
eng = next(a for a in state["agents"] if a["name"] == "Engineer")
rev = next(a for a in state["agents"] if a["name"] == "Reviewer")
con = next(a for a in state["agents"] if a["name"] == "Concierge")
check("apply sets the company", state["company"]["requireBoardApprovalForNewAgents"] is True)
check("apply creates only the missing label", [l["name"] for l in state["labels"]] == ["change", "bug", "sensitive"])
check("apply fixes the engineer", eng["role"] == "engineer" and eng["reportsTo"] == "a1"
      and eng["adapterConfig"]["sessionKeyStrategy"] == "issue" and eng["permissions"]["canCreateAgents"] is False)
check("apply keeps the engineer's key and other runtime settings",
      eng["adapterConfig"]["apiKey"]["secretId"] == "s2" and eng["runtimeConfig"]["keep"] == 1
      and eng["runtimeConfig"]["heartbeat"] == {"enabled": False, "intervalSec": 3600, "maxConcurrentRuns": 2})
check("apply hires and approves the reviewer", rev["status"] == "idle" and rev["reportsTo"] == "a1"
      and rev["adapterConfig"]["apiKey"] == {"type": "secret_ref", "secretId": "s4", "version": "latest"}
      and rev["title"] == "Reviews pull requests" and rev["permissions"] == {"canCreateAgents": False})
check("apply leaves the concierge's adapter settings alone",
      con["adapterConfig"] == {"url": "wss://old.example", "headers": {"x-openclaw-token": "real-token"}})
check("apply never writes a secret value", "real-token" not in json.dumps(fake.writes) and "REDACTED" not in json.dumps(fake.writes))
check("apply revokes its sign-in key", not fake.keys)
health = next(r for r in state["routines"] if r["id"] == "r1")
review = next((r for r in state["routines"] if r["title"] == "Review {{repo}}#{{number}}"), {})
check("apply fixes the health routine", health["description"] == "Check the lab on {{date}}."
      and health["assigneeAgentId"] == "a3" and health["priority"] == "medium"
      and health["concurrencyPolicy"] == "skip_if_active")
check("apply fixes its schedule and leaves the webhook alone",
      [(t["id"], t["cronExpression"], t["timezone"]) for t in state["triggers"]]
      == [("t1", "0 7 * * *", "America/New_York"), ("t2", None, None)])
check("apply creates the review routine for the reviewer it just hired",
      review.get("assigneeAgentId") == rev["id"] and review.get("status") == "active"
      and review.get("concurrencyPolicy") == "always_enqueue"
      and [(v["name"], v["type"], v["options"]) for v in review.get("variables", [])]
      == [("repo", "select", ["nixconfig", "agent-scratch"]), ("number", "number", [])])
check("apply leaves a paused routine paused and untouched",
      not any("/api/routines/r2" in path for _, path, _ in fake.writes)
      and next(r for r in state["routines"] if r["id"] == "r2")["status"] == "paused")

writes = len(fake.writes)
out = run(url, str(spec_path), "--apply")
check("a second run changes nothing", len(fake.writes) == writes and "0 change(s) made" in out)

bad = json.loads(json.dumps(SPEC))
bad["routines"][0]["triggers"].append({"label": "hook", "kind": "webhook"})
bad_path = spec_path.with_name("bad.json")
bad_path.write_text(json.dumps(bad))
writes = len(fake.writes)
env = {k: v for k, v in os.environ.items() if k != "PAPERCLIP_BOARD_KEY"}
proc = subprocess.run([sys.executable, "-I", SCRIPT, "--url", url, "--spec", str(bad_path), "--apply"],
                      capture_output=True, text=True, env=env, timeout=60)
print(proc.stdout + proc.stderr)
check("a webhook trigger in the spec is refused before signing in", proc.returncode != 0
      and "only api and schedule are allowed" in proc.stderr and "Approve" not in proc.stdout
      and len(fake.writes) == writes)

server.shutdown()
if failures:
    sys.exit(f"{len(failures)} check(s) failed")
print("all checks passed")
