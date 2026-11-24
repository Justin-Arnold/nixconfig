#!/usr/bin/env python3
"""notes-scan: checks the vault's new commits for secrets and private data.

Run every 15 minutes by a timer on the agents host (hosts/agents/notes.nix),
as the vault service's user, over the vault's local git history (VAULT).
That history holds every change: each agent's, and Justin's, committed as
"Obsidian Sync" when it arrives. Each pass reads the commits since the last
pass:

1. gitleaks, with its default rules, over every file those commits changed;
2. the vault service's own checks (notes.py, loaded from NOTES_SERVICE) over
   each added line, which add card numbers (Luhn), IBANs (mod 97) and
   social security numbers to what gitleaks finds.

Each finding becomes a code, never the value:

    secret:<rule>:<path>:<line>@<commit>:<who>
    private:<ssn|card|iban>:<path>:<line>@<commit>:<who>

where <who> is the agent whose change added it, or `sync` for a change that
came through Obsidian Sync. A code keeps only [A-Za-z0-9 ._:/@-] in each part.
Codes in SCAN_ALLOW (comma separated) are ones Justin has cleared.

With new codes, it runs the monitor's routine titled ROUTINE_TITLE with the
monitor's own Paperclip key, keyed on the codes, the way lab-health does.
Codes count as handed over once Paperclip created or coalesced the issue;
until then they're tried again on every pass.

STATE_DIR/scan-state.json keeps the last commit read and the codes handed
over; scan-status.json says when a pass last worked and what last went wrong.
Neither holds a value.

--dry-run reads the whole history, prints every code that isn't allowed, and
starts and writes nothing.

Environment: VAULT, STATE_DIR, NOTES_SERVICE, NOTES_PATTERNS, PAPERCLIP_URL,
ROUTINE_TITLE, SCAN_ALLOW, GITLEAKS (gitleaks on PATH), and
CREDENTIALS_DIRECTORY holding paperclip-key.
"""
import codecs
import datetime
import hashlib
import importlib.util
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

MAX_CODES = 40


def load_service():
    spec = importlib.util.spec_from_file_location("notes_service", os.environ["NOTES_SERVICE"])
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


notes = load_service()
STATE_DIR = pathlib.Path(os.environ.get("STATE_DIR", "/var/lib/notes"))


class Refused(Exception):
    """Paperclip didn't take the findings."""


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def part(value):
    return re.sub(r"[^A-Za-z0-9 ._:/@-]", "_", str(value)).strip()[:64] or "_"


def who(email):
    email = (email or "").lower()
    if email.startswith("hermes-") and email.endswith("@agents.invalid"):
        return email[len("hermes-"):-len("@agents.invalid")]
    if email == notes.SYNC_AUTHOR[1]:
        return "sync"
    return "unknown"


def finding(kind, rule, path, line, commit, email):
    return ":".join([kind, part(rule), part(path), f"{line}@{commit[:7]}", part(who(email))])


def unquote_path(raw):
    raw = raw.rstrip("\t")
    if raw.startswith('"') and raw.endswith('"'):
        raw = codecs.escape_decode(raw[1:-1].encode("utf-8"))[0].decode("utf-8", "replace")
    return raw


def own_findings(rev_range):
    """The service's checks over every line the commits in rev_range added."""
    out = notes.git("log", "-p", "-U0", "--no-color", "--no-ext-diff", "--no-renames",
                    "--format=%x1e%H%x1f%ae", rev_range)
    found = []
    for chunk in out.split("\x1e")[1:]:
        header, _, diff = chunk.partition("\n")
        commit, email = header.split("\x1f", 1)
        path, line = None, 0
        for text in diff.split("\n"):
            if text.startswith("+++ "):
                target = text[4:]
                path = None if target == "/dev/null" else unquote_path(target)
                path = path[2:] if path and path.startswith("b/") else path
            elif text.startswith("@@"):
                m = re.search(r"\+(\d+)", text)
                line = int(m.group(1)) if m else 0
            elif text.startswith("+") and path is not None:
                for _, _, _, slug in notes.secret_hits(text[1:]):
                    kind = "private" if slug in notes.PRIVATE_KINDS else "secret"
                    found.append(finding(kind, slug, path, line, commit, email))
                line += 1
    return found


def gitleaks_findings(rev_range):
    with tempfile.TemporaryDirectory() as tmp:
        report = pathlib.Path(tmp) / "report.json"
        ignore = pathlib.Path(tmp) / "ignore"
        ignore.mkdir()
        proc = subprocess.run(
            [os.environ.get("GITLEAKS", "gitleaks"), "git", f"--log-opts={rev_range}", "--report-format=json",
             f"--report-path={report}", "--redact", "--no-banner", "--no-color", "--exit-code=0",
             "--log-level=error", f"--gitleaks-ignore-path={ignore}", str(notes.VAULT)],
            capture_output=True, text=True, timeout=600,
            env={**os.environ, "HOME": str(STATE_DIR), "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"})
        if proc.returncode != 0:
            raise RuntimeError(f"gitleaks failed: {proc.stderr.strip()[:300]}")
        leaks = json.loads(report.read_text() or "[]") if report.exists() else []
    return [finding("secret", leak.get("RuleID"), leak.get("File"), leak.get("StartLine"), leak.get("Commit", ""),
                    leak.get("Email")) for leak in leaks]


def scan(rev_range):
    seen, codes = set(), []
    for code in gitleaks_findings(rev_range) + own_findings(rev_range):
        where = code.split(":", 3)[3]  # path:line@commit:who, so two rules on one line count once
        if where not in seen:
            seen.add(where)
            codes.append(code)
    return codes


def hand_over(codes, key):
    base = os.environ.get("PAPERCLIP_URL", "http://127.0.0.1:3100").rstrip("/")

    def pc(method, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(base + path, data=data, method=method,
                                     headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                text = resp.read().decode()
        except urllib.error.HTTPError as err:
            raise Refused(f"Paperclip answered HTTP {err.code} to {method} {path}") from None
        except (urllib.error.URLError, OSError) as err:
            raise Refused(f"couldn't reach Paperclip: {getattr(err, 'reason', err)}") from None
        return json.loads(text) if text else None

    title = os.environ["ROUTINE_TITLE"]
    me = pc("GET", "/api/agents/me")
    routine = next((r for r in pc("GET", f"/api/companies/{me['companyId']}/routines")
                    if r.get("title") == title and r.get("assigneeAgentId") == me["id"]), None)
    if routine is None:
        raise Refused(f"the monitor has no routine titled {title!r}")
    if routine.get("status") != "active":
        return None, f"the findings routine is {routine.get('status')}, so nothing was started"
    shown = codes[:MAX_CODES] + ([f"and {len(codes) - MAX_CODES} more"] if len(codes) > MAX_CODES else [])
    digest = hashlib.sha256("\n".join(sorted(codes)).encode()).hexdigest()[:16]
    run = pc("POST", f"/api/routines/{routine['id']}/run", {
        "source": "api", "variables": {"count": len(codes), "findings": "; ".join(shown)},
        "idempotencyKey": f"notes-scan:{digest}"}) or {}
    status = run.get("status")
    if status not in ("issue_created", "coalesced", "skipped"):
        raise Refused(f"the findings run came back {status}: {run.get('failureReason') or 'no reason given'}")
    return status, f"handed {len(codes)} finding(s) to the monitor ({status})"


def save(name, value):
    path = STATE_DIR / name
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(value, indent=1))
    os.chmod(tmp, 0o600)
    tmp.replace(path)


def load(name):
    try:
        return json.loads((STATE_DIR / name).read_text())
    except (OSError, ValueError):
        return {}


def main():
    dry = sys.argv[1:] == ["--dry-run"]
    if sys.argv[1:] not in ([], ["--dry-run"]):
        sys.exit("usage: notes-scan.py [--dry-run]")
    allowed = {c.strip() for c in os.environ.get("SCAN_ALLOW", "").split(",") if c.strip()}
    if not notes.has_head():
        print("notes-scan: the vault has no history yet")
        return
    head = notes.git("rev-parse", "HEAD").strip()

    if dry:
        codes = [c for c in scan(head) if c not in allowed]
        for c in codes:
            print(c)
        print(f"notes-scan: {len(codes)} finding(s) in the whole history, nothing started")
        return

    state, status = load("scan-state.json"), load("scan-status.json")
    last = state.get("last_scanned")
    if last == head:
        rev_range = None
    elif last and notes.git("merge-base", "--is-ancestor", last, head, check=False, raw=True).returncode == 0:
        rev_range = f"{last}..{head}"
    else:
        rev_range = head
    error = None
    try:
        new = scan(rev_range) if rev_range else []
    except (RuntimeError, subprocess.TimeoutExpired, ValueError) as err:
        new, error = [], str(err)
    reported = set(state.get("reported", []))
    pending = list(dict.fromkeys(state.get("pending", []) + [c for c in new if c not in reported and c not in allowed]))
    pending = [c for c in pending if c not in allowed]
    result = "nothing to hand over"
    if pending and not error:
        try:
            key = (pathlib.Path(os.environ["CREDENTIALS_DIRECTORY"]) / "paperclip-key").read_text().strip()
            outcome, result = hand_over(pending, key)
            if outcome in ("issue_created", "coalesced"):
                reported |= set(pending)
                pending = []
        except (Refused, KeyError, OSError, ValueError) as err:
            error = str(err)
    if not error:
        state["last_scanned"] = head
    state.update(reported=sorted(reported), pending=pending)
    save("scan-state.json", state)
    print(f"notes-scan: {result}")
    status["last_result"] = result
    if error:
        status.update(last_error=error, last_error_at=now())
        save("scan-status.json", status)
        sys.exit(f"notes-scan: {error}")
    status["last_ok"] = now()
    save("scan-status.json", status)


if __name__ == "__main__":
    main()
