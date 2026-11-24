#!/usr/bin/env python3
"""Tests notes.py and notes-scan.py against a temporary vault and a fake Paperclip.

notes.py's checks are tested in-process. Then the service runs as systemd
would start it, on a socket in a temporary folder, with this test's uid as
the researcher; files written straight into the vault stand in for changes
arriving through Obsidian Sync. notes-scan.py then reads the history it made.

usage: test.py <notes.py> <notes-scan.py> <jev server.py>
"""
import importlib.util
import json
import os
import pathlib
import secrets
import socket
import stat
import string
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SERVICE, SCANNER, JEV = (pathlib.Path(a) for a in sys.argv[1:4])
TMP = pathlib.Path(tempfile.mkdtemp())
VAULT = TMP / "vault"
STATE = TMP / "state"
STATE.mkdir()
os.environ.update(VAULT=str(VAULT), STATE_DIR=str(STATE), NOTES_PATTERNS=str(JEV))
failures = []


def check(what, ok):
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        failures.append(what)


def refused(fn, *args, **kwargs):
    try:
        fn(*args, **kwargs)
    except notes.Refused as err:
        return str(err)
    return None


def token(prefix, n, alphabet=string.ascii_letters + string.digits):
    return prefix + "".join(secrets.choice(alphabet) for _ in range(n))


spec = importlib.util.spec_from_file_location("notes", SERVICE)
notes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notes)
VAULT.mkdir()

# Paths -----------------------------------------------------------------------
for good in ["inbox/idea.md", "Lab/Hosts/agents.md", "Journal 2026.md", "café/notes.md"]:
    check(f"the path {good!r} is fine", refused(notes.clean_path, good) is None)
for bad in ["../x.md", "/etc/x.md", ".git/config", ".obsidian/x.md", "inbox/.hidden.md", "a.txt", "a/./b.md",
            "a//b.md", "a\\b.md", "a:b.md", "folder. /x.md", "a\x07.md", "x#y.md", ""]:
    check(f"the path {bad!r} is refused", refused(notes.clean_path, bad) is not None)
(VAULT / "outside").symlink_to("/etc")
check("a path through a symlink is refused", "symbolic link" in (refused(notes.clean_path, "outside/passwd.md") or ""))
(VAULT / "outside").unlink()

# Secrets ---------------------------------------------------------------------
ghp = token("ghp_", 36)
samples = {
    "a GitHub token": f"my token is {ghp}",
    "an Anthropic key": "key " + token("sk-ant-api03-", 40),
    "a private key": "-----BEGIN OPENSSH PRIVATE KEY-----",
    "a JSON web token": "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
    "a Tailscale key": token("tskey-auth-", 30),
    "a card number": "card 4111 1111 1111 1111 exp 12/29",
    "a social security number": "ssn 123-45-6789",
    "an IBAN": "IBAN GB82 WEST 1234 5698 7654 32",
    "a credential": "password: Tr0ub4dor&3xyz",
}
for kind, text in samples.items():
    check(f"{kind} is refused", refused(notes.refuse_secrets, text, "text") is not None)
for text in ["token: `notes/deploy-key`", "password = <your password here>", "api_key: ${PAPERCLIP_AGENT_KEY}",
             "the token is in 1Password", "card 4111 1111 1111 1112", "at 1700000000000 ms", "port 8443, 2 GB",
             "ssn-like 000-12-3456", "secret: ********"]:
    check(f"{text!r} passes", refused(notes.refuse_secrets, text, "text") is None)
shown, hidden = notes.redact(f"before {ghp} after")
check("redaction hides the token and says so", ghp not in shown and "⟦redacted: a GitHub token⟧" in shown and hidden)
check("text carrying the marker back is refused", "marker" in (refused(notes.refuse_secrets, shown, "content") or ""))

# Parsing ---------------------------------------------------------------------
parsed = notes.parse("Projects/Plan.md", "---\ntags: [lab, todo]\naliases:\n  - Roadmap draft\n---\n"
                     "# Plan\n\nSee [[Home]] and [[Ideas#Later|later]] and [the host](../Lab/agents.md).\n"
                     "#project/big and `#notatag`\n```\n# not a heading [[NotALink]]\n```\n## Later\n")
check("front matter tags and inline tags are read", parsed["tags"] == ["lab", "project/big", "todo"])
check("aliases are read", parsed["aliases"] == ["Roadmap draft"])
check("headings outside code are read", [h["text"] for h in parsed["headings"]] == ["Plan", "Later"])
check("wiki and Markdown links are read, outside code",
      [(l["target"], l["heading"]) for l in parsed["links"]] == [("Home", None), ("Ideas", "Later"), ("../Lab/agents.md", None)])

# The service -------------------------------------------------------------------
(VAULT / "Projects").mkdir()
(VAULT / "Home.md").write_text("# Home\n\nStart at [[Plan]]. #index\n")
(VAULT / "Projects" / "Plan.md").write_text("---\ntags: [lab]\n---\n# Plan\n\nThe lab plan.\n\n## Now\n\n- one\n\n"
                                            "## Later\n\n- two\n")
(VAULT / "Private.md").write_text(f"# Private\n\nold key {ghp}\n")
(VAULT / ".obsidian").mkdir()
(VAULT / ".obsidian" / "app.json").write_text("{}")

SOCK = TMP / "notes.sock"


def start(agents, **extra):
    env = {**os.environ, "NOTES_AGENTS": agents, "NOTES_LISTEN": str(SOCK), "WATCH_SECONDS": "0.5", **extra}
    if SOCK.exists():
        SOCK.unlink()
    proc = subprocess.Popen([sys.executable, "-I", str(SERVICE)], env=env)
    for _ in range(200):
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
                s.connect(str(SOCK))
            break
        except OSError:
            time.sleep(0.05)
    return proc


def call(op, **args):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.connect(str(SOCK))
        s.sendall(json.dumps({"op": op, "args": args}).encode() + b"\n")
        s.shutdown(socket.SHUT_WR)
        data = b""
        while chunk := s.recv(65536):
            data += chunk
    return json.loads(data)


def ok(reply):
    return reply.get("result") if reply.get("ok") else None


def git(*args):
    return subprocess.run(["git", "-C", str(VAULT), *args], capture_output=True, text=True).stdout


def wait_for_commit(count):
    for _ in range(100):
        if int(git("rev-list", "--count", "HEAD").strip() or 0) >= count:
            return True
        time.sleep(0.05)
    return False


uid = os.getuid()
proc = start(f"{uid}=researcher")
check("the first start commits what's there as Obsidian Sync",
      git("log", "-1", "--format=%an").strip() == "Obsidian Sync")
check("dot-folders stay out of git", ".obsidian" not in git("ls-files"))

found = ok(call("search_notes", query="plan"))
check("search finds the note by its title first", found and found["results"][0]["path"] == "Projects/Plan.md")
check("search by tag", [r["path"] for r in ok(call("search_notes", tag="index"))["results"]] == ["Home.md"])
check("search in a folder", [r["path"] for r in ok(call("search_notes", query="the", folder="Projects"))["results"]]
      == ["Projects/Plan.md"])
hit = ok(call("search_notes", query="key"))
check("search snippets are redacted", hit and ghp not in json.dumps(hit) and "redacted" in json.dumps(hit))

note = ok(call("read_note", path="Plan"))
check("a note is read by its link target", note and note["path"] == "Projects/Plan.md" and "The lab plan." in note["content"])
check("a read has the revision, headings and tags", note["revision"] and [h["text"] for h in note["headings"]]
      == ["Plan", "Now", "Later"] and note["tags"] == ["lab"])
secret_note = ok(call("read_note", path="Private.md"))
check("a read hides a secret and says so", ghp not in secret_note["content"] and secret_note["redacted"])
check("links out are resolved", ok(call("read_note", path="Home.md"))["links_out"][0]["path"] == "Projects/Plan.md")

listed = ok(call("list_notes"))
check("list shows folders and notes at the top", listed["folders"] == ["Projects"]
      and [n["path"] for n in listed["notes"]] == ["Home.md", "Private.md"])
check("list recursive", len(ok(call("list_notes", recursive=True))["notes"]) == 3)
check("backlinks", [b["path"] for b in ok(call("backlinks", path="Projects/Plan.md"))["backlinks"]] == ["Home.md"])

created = ok(call("create_note", path="inbox/test.md", content="# Test\n\nfirst", message="Add a test note (LAB-1)"))
check("create writes the note", created and (VAULT / "inbox" / "test.md").read_text() == "# Test\n\nfirst\n")
log = git("log", "-1", "--format=%an|%ae|%cn|%s|%b")
check("the commit is the researcher's, with its trailers", log.startswith(
    "Researcher (agent)|hermes-researcher@agents.invalid|notes service|Add a test note (LAB-1)|Agent: researcher\nTool: create_note"))
check("a second create is refused", "already exists" in call("create_note", path="inbox/test.md", content="x",
                                                                message="again").get("error", ""))
check("a path differing only in case is refused", "case" in call("create_note", path="Inbox/other.md", content="x",
                                                                  message="x").get("error", ""))
check("a path outside the vault is refused", not call("create_note", path="../x.md", content="x", message="x")["ok"])
check("no temporary files are left", not list(VAULT.rglob(".notes-*")))

(VAULT / "Home.md").write_text("# Home\n\nStart at [[Plan]]. #index\n\nJustin's line.\n")
appended = ok(call("append_to_note", path="Projects/Plan.md", text="- three", heading="Now", message="Add three"))
plan = (VAULT / "Projects" / "Plan.md").read_text()
check("append under a heading lands at the end of that section", appended and "- one\n\n- three\n\n## Later" in plan)
last_two = git("log", "-2", "--format=%an %s", "--name-only")
check("a change from Sync is committed apart, before the agent's", "Obsidian Sync" in last_two
      and git("show", "--name-only", "--format=", "HEAD").split() == ["Projects/Plan.md"])
check("append to a missing note is refused", not call("append_to_note", path="nope.md", text="x", message="x")["ok"])
check("append with create makes it", ok(call("append_to_note", path="inbox/log.md", text="entry", message="log",
                                             create=True, heading="Log")) is not None
      and (VAULT / "inbox" / "log.md").read_text() == "## Log\n\nentry\n")

twice = call("replace_in_note", path="Projects/Plan.md", old="- t", new="- T", message="x")
check("an ambiguous replace is refused, with the count", "2 times" in twice.get("error", ""))
check("a replace that matches nothing is refused", "doesn't contain" in call(
    "replace_in_note", path="Projects/Plan.md", old="nothing like this", new="x", message="x").get("error", ""))
check("a unique replace works", ok(call("replace_in_note", path="Projects/Plan.md", old="- three", new="- 3",
                                        message="Number it")) and "- 3\n" in (VAULT / "Projects/Plan.md").read_text())

stale = call("rewrite_note", path="Projects/Plan.md", content="# Plan\n", revision=note["revision"], message="x")
check("a rewrite of a note that changed since it was read is refused", "changed since you read it" in stale.get("error", ""))
fresh = ok(call("read_note", path="Projects/Plan.md"))
check("a rewrite of the current revision works", ok(call("rewrite_note", path="Projects/Plan.md",
                                                         content=fresh["content"] + "\nMore.\n",
                                                         revision=fresh["revision"], message="More")) is not None)
private = ok(call("read_note", path="Private.md"))
check("a rewrite carrying the redaction marker is refused", "marker" in call(
    "rewrite_note", path="Private.md", content=private["content"] + "\nx\n", revision=private["revision"],
    message="x").get("error", ""))
check("an edit next to Justin's secret still works", ok(call("append_to_note", path="Private.md", text="more",
                                                             message="x")) is not None)

before = git("rev-parse", "HEAD")
refusals = [
    call("create_note", path="inbox/key.md", content=f"the key {token('ghp_', 36)}", message="x"),
    call("append_to_note", path="Home.md", text="ssn 123-45-6789", message="x"),
    call("replace_in_note", path="Home.md", old="Justin's line.", new="card 4111 1111 1111 1111", message="x"),
    call("create_note", path="inbox/ok.md", content="fine", message=f"with {token('ghp_', 36)}"),
]
check("secrets in content, text, new and message are refused", all("never goes in the vault" in r.get("error", "")
                                                                   for r in refusals))
check("  ...and nothing was written or committed", git("rev-parse", "HEAD") == before
      and not (VAULT / "inbox" / "key.md").exists() and not (VAULT / "inbox" / "ok.md").exists())
check("a placeholder passes", ok(call("append_to_note", path="Home.md", text="token: `notes/deploy-key`",
                                      message="Say where the key is")) is not None)

moved = ok(call("move_note", path="Projects/Plan.md", new_path="Projects/Roadmap.md", message="Rename the plan"))
home = (VAULT / "Home.md").read_text()
check("a move renames the note and updates links to it", moved and (VAULT / "Projects/Roadmap.md").exists()
      and "[[Roadmap]]" in home and moved["links_updated"] == ["Home.md"])
check("  ...in one commit", sorted(git("show", "--no-renames", "--name-only", "--format=", "HEAD").split())
      == ["Home.md", "Projects/Plan.md", "Projects/Roadmap.md"])
history = ok(call("note_history", path="Projects/Roadmap.md", limit=20))["history"]
check("history follows the move", history[0]["change"] == "moved from Projects/Plan.md"
      and any(h["author"] == "Obsidian Sync" for h in history))
old = ok(call("read_note", path=history[-1]["path"], revision=history[-1]["commit"]))
check("an old version reads by commit, at the path it had then", history[-1]["path"] == "Projects/Plan.md"
      and old and "The lab plan." in old["content"] and "- 3" not in old["content"])

(VAULT / "Justin.md").write_text("written in Obsidian\n")
check("the watch commits a change from Sync on its own", wait_for_commit(int(git("rev-list", "--count", "HEAD")) + 1)
      and git("log", "-1", "--format=%an").strip() == "Obsidian Sync")
status_text = (STATE / "status.json").read_text()
check("status.json says when it last worked, and only its owner reads it",
      "last_ok" in status_text and stat.S_IMODE((STATE / "status.json").stat().st_mode) == 0o600)
check("an unknown operation is refused", not call("delete_note", path="Home.md")["ok"])
check("unknown arguments are refused", "doesn't take" in call("list_notes", nope=1).get("error", ""))
proc.terminate()
proc.wait()

proc = start("1=coordinator")
check("a caller whose uid isn't an agent's is refused", "isn't one of the agents" in call("list_notes").get("error", ""))
proc.terminate()
proc.wait()

proc = start(f"{uid}=engineer", WRITES_PER_HOUR="2")
results = [call("create_note", path=f"inbox/limit-{i}.md", content="x", message="x")["ok"] for i in range(3)]
check("writes past the hourly limit are refused", results == [True, True, False])
check("  ...and the engineer is the author", git("log", "-1", "--format=%ae").strip() == "hermes-engineer@agents.invalid")
proc.terminate()
proc.wait()

# The scanner -------------------------------------------------------------------
posts, run_status = [], ["issue_created"]


class Paperclip(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, body):
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.headers.get("Authorization") != "Bearer monitor-key":
            self.send_response(401)
            self.end_headers()
        elif self.path == "/api/agents/me":
            self.reply({"id": "mon", "companyId": "co"})
        else:
            self.reply([{"id": "r1", "title": "Look into {{count}} vault finding(s)", "assigneeAgentId": "mon",
                         "status": "active"}])

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        posts.append(body)
        self.reply({"status": run_status[0]})


httpd = ThreadingHTTPServer(("127.0.0.1", 0), Paperclip)
threading.Thread(target=httpd.serve_forever, daemon=True).start()
creds = TMP / "creds"
creds.mkdir()
(creds / "paperclip-key").write_text("monitor-key\n")
scan_env = {**os.environ, "NOTES_SERVICE": str(SERVICE), "PAPERCLIP_URL": f"http://127.0.0.1:{httpd.server_port}",
            "ROUTINE_TITLE": "Look into {{count}} vault finding(s)", "CREDENTIALS_DIRECTORY": str(creds)}


def scan(*args, **env):
    return subprocess.run([sys.executable, "-I", str(SCANNER), *args], env={**scan_env, **env},
                          capture_output=True, text=True)


(VAULT / "Money.md").write_text("pay with 4111 1111 1111 1111\n")
subprocess.run(["git", "-C", str(VAULT), "add", "-A"], check=True)
subprocess.run(["git", "-C", str(VAULT), "-c", "user.name=Obsidian Sync", "-c", "user.email=sync@notes.invalid",
                "commit", "-qm", "Obsidian Sync: 1 file(s)"], check=True)

dry = scan("--dry-run")
check("the dry run finds the old GitHub token and the card", dry.returncode == 0
      and ":Private.md:3@" in dry.stdout and "private:card:Money.md:1@" in dry.stdout and ":sync" in dry.stdout)
check("  ...never prints a value", ghp not in dry.stdout and "4111" not in dry.stdout)
check("  ...and starts and writes nothing", not posts and not (STATE / "scan-state.json").exists())

first = scan()
check("a pass hands the findings to the monitor", first.returncode == 0 and len(posts) == 1
      and posts[0]["variables"]["count"] >= 2 and posts[0]["idempotencyKey"].startswith("notes-scan:"))
check("  ...without a value in what it sends", ghp not in json.dumps(posts) and "4111" not in json.dumps(posts))
check("a second pass starts nothing", scan().returncode == 0 and len(posts) == 1)

(VAULT / "Who.md").write_text("ssn 123-45-6789\n")
subprocess.run(["git", "-C", str(VAULT), "add", "-A"], check=True)
subprocess.run(["git", "-C", str(VAULT), "-c", "user.name=Researcher (agent)",
                "-c", "user.email=hermes-researcher@agents.invalid", "commit", "-qm", "x"], check=True)
run_status[0] = "skipped"
scan()
state = json.loads((STATE / "scan-state.json").read_text())
check("a skipped run keeps the finding pending, under the agent's name",
      len(posts) == 2 and any(c.startswith("private:ssn:Who.md:1@") and c.endswith(":researcher") for c in state["pending"]))
run_status[0] = "issue_created"
scan()
check("  ...and hands it over on a later pass", len(posts) == 3 and not json.loads(
    (STATE / "scan-state.json").read_text())["pending"])
dry_codes = [line for line in scan("--dry-run").stdout.splitlines() if ":" in line and " " not in line.split(":")[0]]
allowed = scan("--dry-run", SCAN_ALLOW=",".join(dry_codes))
check("codes in SCAN_ALLOW aren't reported", "0 finding(s)" in allowed.stdout)
for name in ("scan-state.json", "scan-status.json"):
    text = (STATE / name).read_text()
    check(f"{name} holds no value and only its owner reads it", ghp not in text and "4111" not in text
          and stat.S_IMODE((STATE / name).stat().st_mode) == 0o600)

httpd.shutdown()
if failures:
    sys.exit(f"{len(failures)} check(s) failed")
print("all checks passed")
