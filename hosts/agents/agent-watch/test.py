#!/usr/bin/env python3
"""Runs agent-watch.py against a fake Paperclip, Alerta and Kuma.

Two passes over a Paperclip with something wrong of every kind, then a third
after most of it is fixed, and one with Paperclip failing. Checks which
alerts are raised and cleared, that repeats are identical so the forwarder
stays quiet, that questions for the board and issues blocked on it link to
Paperclip, and that Kuma only hears about passes that worked.

usage: test.py <agent-watch.py>
"""
import datetime
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SCRIPT = sys.argv[1]
CID = "c1"
NOW = datetime.datetime.now(datetime.timezone.utc)
TOKEN = "KumaPushToken0123"


def ago(minutes):
    return (NOW - datetime.timedelta(minutes=minutes)).isoformat().replace("+00:00", "Z")


def run(agent, status, error=None, minutes=5):
    return {"id": f"r-{agent}-{minutes}", "agentId": agent, "status": status, "error": error, "createdAt": ago(minutes)}


def issue(number, status, minutes, active=False, title="Something", unblock=None):
    return {"id": f"i{number}", "identifier": f"LAB-{number}", "title": title, "status": status,
            "lastActivityAt": ago(minutes), "updatedAt": ago(minutes),
            "activeRun": {"id": "r", "status": "running"} if active else None, "unblockDescriptor": unblock}


def ask(iid, status="pending", title=None, prompt="Which bar replaces hyprpanel?", minutes=5):
    return {"id": iid, "kind": "ask_user_questions", "status": status, "title": title, "createdAt": ago(minutes),
            "payload": {"version": 1, "questions": [{"id": "q1", "prompt": prompt, "selectionMode": "single",
                                                     "options": [{"id": "a", "label": "wayle"}]}]}}


class Fake:
    def __init__(self):
        self.agents = [
            {"id": "a1", "name": "Coordinator", "status": "idle"},
            {"id": "a2", "name": "Engineer", "status": "error", "errorReason": "adapter failed"},
            {"id": "a3", "name": "Researcher", "status": "idle"},
            {"id": "a4", "name": "Concierge", "status": "running"},
        ]
        self.runs = {
            "a1": [run("a1", "succeeded")],
            "a2": [run("a2", "failed", "Codex said:\n  model not supported", 5), run("a2", "succeeded", minutes=60)],
            "a3": [run("a3", "timed_out", minutes=10), run("a3", "succeeded", minutes=90)],
            # A run in flight doesn't count; the one before it decides.
            "a4": [run("a4", "running", minutes=1), run("a4", "succeeded", minutes=30)],
        }
        self.issues = [
            issue(1, "in_progress", 180, title="Stuck with no run"),
            issue(2, "in_progress", 180, active=True),
            issue(3, "in_progress", 10),
        ]
        self.labelled = {"lc": [issue(4, "todo", 5, title="Switch the agents host")], "ls": []}
        # Issues where the board might be wanted: one asks a question, one is
        # blocked on the board, one is blocked on another issue, and one only
        # has a question that's been answered.
        self.asking = [
            issue(5, "blocked", 5, title="Update flake.lock",
                  unblock={"owner": "board", "action": "Pick hyprpanel's replacement"}),
            issue(6, "in_progress", 5, title="Review a pull request"),
            issue(7, "blocked", 5, unblock={"owner": {"agentId": "a1"}, "action": "Wait for LAB-3"}),
            issue(8, "in_review", 5),
        ]
        self.interactions = {
            "i6": [ask("x1", prompt="Which bar replaces hyprpanel?", minutes=10),
                   ask("x2", prompt="And pnpm?", minutes=2), ask("x0", status="answered", minutes=30)],
            "i8": [ask("x3", status="answered")],
        }
        self.approvals = [{"id": "ap123456789", "type": "hire_agent", "status": "pending", "payload": {"name": "Reviewer"}}]
        self.budgets = [{"id": "b1234567890", "scopeType": "company", "status": "warning", "warnPercent": 80},
                        {"id": "b2", "scopeType": "agent", "status": "ok", "warnPercent": 80}]
        self.paperclip_broken = False
        self.kuma_broken = False
        # Alerta: an alert from an earlier pass that no longer holds, and one
        # from someone else that must be left alone.
        self.alerta = {
            ("paperclip/LAB-9", "IssueStuck"): {"resource": "paperclip/LAB-9", "event": "IssueStuck", "origin": "agent-watch",
                                                "environment": "Homelab", "status": "open", "severity": "warning"},
            ("SVC / gitea", "http"): {"resource": "SVC / gitea", "event": "http", "origin": "uptimekuma",
                                      "environment": "Homelab", "status": "open", "severity": "critical"},
        }
        self.posts = []
        self.pushes = []
        self.requests = []
        self.lock = threading.Lock()

    def paperclip(self, path, query, auth):
        if auth != "Bearer pc-key":
            return 401, {"error": "unauthorized"}
        if self.paperclip_broken:
            return 500, {"error": "database unavailable"}
        base = f"/api/companies/{CID}"
        if path == "/api/agents/me":
            return 200, {"id": "a3", "companyId": CID}
        if path == f"{base}/agents":
            return 200, self.agents
        if path == f"{base}/heartbeat-runs":
            assert "limit" in query, "heartbeat-runs without a limit returns every run"
            return 200, self.runs[query["agentId"][0]]
        if path == f"{base}/issues":
            assert "limit" in query, query
            if "labelId" in query:
                assert query["status"] == ["backlog,todo,in_progress,in_review,blocked"], query
                return 200, self.labelled[query["labelId"][0]]
            if query["status"] == ["todo,in_progress,in_review,blocked"]:
                return 200, self.asking
            assert query["status"] == ["in_progress"], query
            return 200, self.issues
        if path.startswith("/api/issues/") and path.endswith("/interactions"):
            return 200, self.interactions.get(path.split("/")[3], [])
        if path == f"{base}/approvals":
            assert query["status"] == ["pending"], query
            return 200, [a for a in self.approvals if a["status"] == "pending"]
        if path == f"{base}/labels":
            return 200, [{"id": "lc", "name": "change"}, {"id": "ls", "name": "sensitive"}, {"id": "lb", "name": "bug"}]
        if path == f"{base}/budgets/overview":
            return 200, {"policies": self.budgets}
        return 404, {"error": f"no route {path}"}

    def handle(self, method, path, query, body, auth):
        self.requests.append((method, path))
        if path.startswith("/api/"):
            assert method == "GET", f"agent-watch wrote to Paperclip: {method} {path}"
            return self.paperclip(path, query, auth)
        if path.startswith("/alerta/"):
            if auth != "Key alerta-key":
                return 401, {"status": "error"}
            if method == "GET" and path == "/alerta/alerts":
                assert query["environment"] == ["Homelab"] and query["origin"] == ["agent-watch"], query
                statuses = set(query["status"])
                return 200, {"alerts": [a for a in self.alerta.values()
                                        if a["origin"] == query["origin"][0] and a["status"] in statuses]}
            if method == "POST" and path == "/alerta/alert":
                self.posts.append(body)
                closed = body["severity"] in ("cleared", "normal", "ok")
                self.alerta[(body["resource"], body["event"])] = {**body, "status": "closed" if closed else "open"}
                return 201, {"status": "ok"}
        if path.startswith("/kuma/push/"):
            if self.kuma_broken:
                return 404, {"ok": False, "msg": "Monitor not found or not active."}
            assert set(query) == {"status", "msg"}, query
            self.pushes.append(query["status"][0])
            return 200, {"ok": True}
        return 404, {"error": f"no route {method} {path}"}


def serve(fake):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def respond(self):
            url = urllib.parse.urlsplit(self.path)
            length = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(length)) if length else None
            with fake.lock:
                try:
                    status, out = fake.handle(self.command, url.path, urllib.parse.parse_qs(url.query), body,
                                              self.headers.get("Authorization") or "")
                except AssertionError as err:
                    status, out = 500, {"error": f"fake refused: {err}"}
                    print(f"fake refused: {err}")
            data = json.dumps(out).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        do_GET = do_POST = respond

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


fake = Fake()
server = serve(fake)
url = f"http://127.0.0.1:{server.server_address[1]}"
creds = pathlib.Path(tempfile.mkdtemp())
(creds / "paperclip-key").write_text("pc-key\n")
(creds / "alerta-key").write_text("alerta-key\n")
(creds / "kuma-push-url").write_text(f"{url}/kuma/push/{TOKEN}?status=up&msg=OK&ping=\n")
env = {"PATH": os.environ.get("PATH", ""), "CREDENTIALS_DIRECTORY": str(creds),
       "PAPERCLIP_URL": url, "ALERTA_URL": f"{url}/alerta", "STUCK_AFTER_MINUTES": "60",
       "PAPERCLIP_LINK": "https://paperclip.example/LAB/"}


def watch():
    fake.posts.clear()
    proc = subprocess.run([sys.executable, "-I", SCRIPT], capture_output=True, text=True, env=env, timeout=60)
    watch.output = proc.stdout + proc.stderr
    print(watch.output, end="")
    return proc.returncode, {(p["resource"], p["event"]): p for p in fake.posts}


failures = []


def check(what, ok):
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        failures.append(what)


code, sent = watch()
raised = {k for k, p in sent.items() if p["severity"] != "cleared"}
check("a pass succeeds", code == 0)
check("raises exactly what's wrong", raised == {
    ("paperclip/engineer", "RunFailed"), ("paperclip/researcher", "RunFailed"), ("paperclip/LAB-1", "IssueStuck"),
    ("paperclip/approval-ap123456", "ApprovalWaiting"), ("paperclip/LAB-4", "MarkedChange"),
    ("paperclip/budget-b1234567", "BudgetWarning"), ("paperclip/LAB-5", "WaitingOnYou"),
    ("paperclip/LAB-6", "WaitingOnYou")})
check("clears its own alert that no longer holds",
      sent.get(("paperclip/LAB-9", "IssueStuck"), {}).get("severity") == "cleared")
check("leaves other origins' alerts alone", ("SVC / gitea", "http") not in sent)
eng = sent.get(("paperclip/engineer", "RunFailed"), {})
check("says why a run failed, on one line", eng.get("text") == "Engineer: its last run failed: Codex said: model not supported"
      and eng.get("severity") == "minor" and eng.get("environment") == "Homelab" and eng.get("origin") == "agent-watch")
check("names a timed-out run", sent.get(("paperclip/researcher", "RunFailed"), {}).get("text")
      == "Researcher: its last run timed out.")
check("gives a readable title", eng.get("attributes") == {"notificationTitle": "Paperclip: Engineer failed"})
check("names the approval", sent.get(("paperclip/approval-ap123456", "ApprovalWaiting"), {}).get("text")
      == "Waiting on you: a new agent: Reviewer")
check("links the approval", sent.get(("paperclip/approval-ap123456", "ApprovalWaiting"), {}).get("attributes")
      == {"notificationTitle": "Paperclip: approval waiting", "url": "https://paperclip.example/LAB/approvals/ap123456789"})
asks = sent.get(("paperclip/LAB-6", "WaitingOnYou"), {})
check("names the oldest question waiting on an issue", asks.get("text") == "LAB-6 asks: Which bar replaces hyprpanel?")
check("links the issue", asks.get("attributes") == {"notificationTitle": "Paperclip: LAB-6 needs you",
                                                     "url": "https://paperclip.example/LAB/issues/LAB-6"})
check("names what an issue blocked on the board needs", sent.get(("paperclip/LAB-5", "WaitingOnYou"), {}).get("text")
      == "LAB-5 waits on you: Pick hyprpanel's replacement")
check("reports to Kuma", fake.pushes == ["up"])
check("only reads Paperclip", all(m == "GET" for m, p in fake.requests if p.startswith("/api/")))

first = sent
code, sent = watch()
check("a repeat pass sends the same alerts unchanged", code == 0 and {k: v for k, v in first.items() if v["severity"] != "cleared"} == sent)

fake.agents[1] = {"id": "a2", "name": "Engineer", "status": "idle"}
fake.runs["a2"].insert(0, run("a2", "succeeded", minutes=1))
fake.approvals[0]["status"] = "approved"
fake.issues[0]["activeRun"] = {"id": "r9", "status": "running"}
for interaction in fake.interactions["i6"]:
    interaction["status"] = "answered"
fake.asking[0].update(status="in_progress", unblockDescriptor=None)
code, sent = watch()
check("clears what was fixed, and questions once answered", code == 0 and {k for k, p in sent.items() if p["severity"] == "cleared"} == {
    ("paperclip/engineer", "RunFailed"), ("paperclip/approval-ap123456", "ApprovalWaiting"), ("paperclip/LAB-1", "IssueStuck"),
    ("paperclip/LAB-5", "WaitingOnYou"), ("paperclip/LAB-6", "WaitingOnYou")})
check("keeps what still holds", {k for k, p in sent.items() if p["severity"] != "cleared"} == {
    ("paperclip/researcher", "RunFailed"), ("paperclip/LAB-4", "MarkedChange"), ("paperclip/budget-b1234567", "BudgetWarning")})

fake.kuma_broken = True
code, sent = watch()
check("fails when Kuma does, without printing the push token",
      code != 0 and "the Kuma push URL on 127.0.0.1" in watch.output and TOKEN not in watch.output)
fake.kuma_broken = False

fake.paperclip_broken = True
pushes = len(fake.pushes)
code, sent = watch()
check("fails when Paperclip does, without touching Alerta or Kuma", code != 0 and sent == {} and len(fake.pushes) == pushes)

# Credit alerts, from agent-costs' month.json files.
costs = pathlib.Path(tempfile.mkdtemp())
MONTH = NOW.strftime("%Y-%m")


def spend(agent, cents, claude=(None, None), jev=(None, None), month=MONTH):
    (costs / agent).mkdir(exist_ok=True)
    (costs / agent / "month.json").write_text(json.dumps({
        "agent": agent, "month": month,
        "claude": {"cents": str(cents), "last_ok": claude[0], "last_refused": claude[1]},
        "jev": {"cents": "0.01", "last_ok": jev[0], "last_refused": jev[1]}}))


fake.paperclip_broken = False
env.update({"COSTS_DIR": str(costs), "CLAUDE_MONTHLY_CREDITS": "100", "CLAUDE_WARN_PERCENT": "80"})
spend("reviewer", 7000, claude=(ago(60), ago(5)), jev=(ago(5), ago(60)))
spend("coordinator", 1500, claude=(ago(30), None))
spend("engineer", 9000, month="2000-01")
(costs / "broken").mkdir()
(costs / "broken" / "month.json").write_text("{not json")
code, sent = watch()
credit = {k: p for k, p in sent.items() if k[0] in ("anthropic/credits", "typesafe/credits")}
check("a pass with spend files succeeds, skipping one it can't read", code == 0 and "skipping" in watch.output)
check("$85 of $100 this month raises ClaudeSpend as a warning, not counting last month",
      credit.get(("anthropic/credits", "ClaudeSpend"), {}).get("severity") == "warning"
      and "passed 80% of the $100" in credit[("anthropic/credits", "ClaudeSpend")]["text"])
out = credit.get(("anthropic/credits", "ClaudeCreditsOut"), {})
check("Claude refusing the reviewer since it last worked raises ClaudeCreditsOut naming it",
      out.get("severity") == "major" and "refused reviewer for credits" in out.get("text", "")
      and out.get("service") == ["Agents"])
check("Jev working again after a refusal raises nothing", ("typesafe/credits", "JevCreditsOut") not in credit)

spend("reviewer", 9000, claude=(ago(1), ago(5)), jev=(ago(60), ago(2)))
code, sent = watch()
check("Claude working again clears ClaudeCreditsOut",
      sent.get(("anthropic/credits", "ClaudeCreditsOut"), {}).get("severity") == "cleared"
      and sent[("anthropic/credits", "ClaudeCreditsOut")]["service"] == ["Agents"])
check("spend past the whole $100 makes ClaudeSpend major",
      sent.get(("anthropic/credits", "ClaudeSpend"), {}).get("severity") == "major")
check("Jev refusing the reviewer since it last worked raises JevCreditsOut",
      "refused reviewer for credits" in sent.get(("typesafe/credits", "JevCreditsOut"), {}).get("text", ""))

# IntakeStale, from monitor-intake's status.json.
intake_dir = pathlib.Path(tempfile.mkdtemp())
status_file = intake_dir / "status.json"
env.update({"INTAKE_STATUS": str(status_file), "INTAKE_STALE_MINUTES": "15"})
STALE = ("agents/monitor-intake", "IntakeStale")


def intake_status(**values):
    status_file.write_text(json.dumps({"started": ago(600), "last_ok": None, "last_error": None,
                                       "last_error_at": None, **values}))


code, sent = watch()
check("no status yet, from a folder made just now, raises nothing", code == 0 and STALE not in sent)
old = (NOW - datetime.timedelta(minutes=30)).timestamp()
os.utime(intake_dir, (old, old))
code, sent = watch()
check("no status from a folder made 30 minutes ago raises IntakeStale",
      sent.get(STALE, {}).get("text") == "monitor-intake hasn't handed new alerts to the monitor since it was set up.")
intake_status(last_ok=ago(5))
code, sent = watch()
check("a good pass 5 minutes ago clears it", sent.get(STALE, {}).get("severity") == "cleared")
intake_status(last_ok=ago(30), last_error="the triage run came back failed: daily run limit reached",
              last_error_at=ago(1), waiting=3)
code, sent = watch()
stale = sent.get(STALE, {})
check("no good pass for 30 minutes raises IntakeStale with the reason",
      stale.get("severity") == "warning" and stale.get("service") == ["Agents"]
      and stale.get("text", "").startswith("monitor-intake hasn't handed new alerts to the monitor since ")
      and stale.get("text", "").endswith(": the triage run came back failed: daily run limit reached"))
intake_status(last_ok=ago(30), last_error="the triage run came back failed: daily run limit reached",
              last_error_at=ago(0), waiting=4)
code, sent = watch()
check("its text doesn't change while the cause doesn't", sent.get(STALE, {}).get("text") == stale.get("text"))
intake_status(last_ok=ago(30), last_error="cannot reach Alerta", last_error_at=ago(60))
code, sent = watch()
check("an error older than the last good pass isn't given as the reason",
      sent.get(STALE, {}).get("text", "").endswith(" UTC."))
status_file.write_text("{not json")
os.utime(intake_dir, (old, old))
code, sent = watch()
check("a status it can't read raises IntakeStale saying so",
      sent.get(STALE, {}).get("text", "").endswith(": its status file can't be read"))

# BridgeStale, from board-bridge's status.json, the same way.
bridge_dir = pathlib.Path(tempfile.mkdtemp())
bridge_file = bridge_dir / "status.json"
env.update({"BRIDGE_STATUS": str(bridge_file), "BRIDGE_STALE_MINUTES": "15"})
BRIDGE = ("agents/board-bridge", "BridgeStale")
bridge_file.write_text(json.dumps({"started": ago(600), "last_ok": ago(3)}))
code, sent = watch()
check("a bridge that passed 3 minutes ago raises nothing", code == 0 and BRIDGE not in sent)
bridge_file.write_text(json.dumps({"started": ago(600), "last_ok": ago(40), "last_error_at": ago(1),
                                   "last_error": "Telegram: getUpdates: Unauthorized"}))
code, sent = watch()
check("a bridge with no good pass for 40 minutes raises BridgeStale with the reason",
      sent.get(BRIDGE, {}).get("severity") == "warning"
      and sent[BRIDGE]["text"].startswith("board-bridge hasn't had a good pass since ")
      and sent[BRIDGE]["text"].endswith(": Telegram: getUpdates: Unauthorized"))

# EventsStale, from paperclip-events' status.json, after 5 minutes.
events_dir = pathlib.Path(tempfile.mkdtemp())
events_file = events_dir / "status.json"
env.update({"EVENTS_STATUS": str(events_file), "EVENTS_STALE_MINUTES": "5"})
EVENTS = ("agents/paperclip-events", "EventsStale")
events_file.write_text(json.dumps({"started": ago(600), "connected": True, "last_ok": ago(1)}))
code, sent = watch()
check("a relay connected a minute ago raises nothing", code == 0 and EVENTS not in sent)
events_file.write_text(json.dumps({"started": ago(600), "connected": False, "last_ok": ago(8), "last_error_at": ago(2),
                                   "last_error": "not connected: GET /api/agents/me answered 401"}))
code, sent = watch()
check("a relay disconnected for 8 minutes raises EventsStale with the reason",
      sent.get(EVENTS, {}).get("severity") == "warning"
      and sent[EVENTS]["text"].startswith("paperclip-events hasn't been connected since ")
      and sent[EVENTS]["text"].endswith(": not connected: GET /api/agents/me answered 401"))

server.shutdown()
if failures:
    sys.exit(f"{len(failures)} check(s) failed")
print("all checks passed")
