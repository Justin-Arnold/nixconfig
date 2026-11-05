#!/usr/bin/env python3
"""monitor-intake: new Alerta alerts, handed to the monitor agent to triage.

One pass, run every 2 minutes by a timer on the agents host
(hosts/agents/monitor-intake.nix):

1. Read Alerta's open alerts with a key that can only read. Alerts from an
   origin in IGNORE_ORIGINS (agent-watch, so the agents' own trouble can't
   loop back to them) are skipped, and so are severities not in SEVERITIES.
2. What's new is what's open and hasn't been handed over yet. An alert that
   closes is forgotten, so it's new again if it opens again.
3. If the monitor is still on an earlier triage (an issue from the routine
   that's todo or in progress), wait: the new alerts join the next batch.
   An issue left blocked or in review doesn't hold anything up.
4. Otherwise start the routine titled ROUTINE_TITLE with the alert ids and
   how many there are, at most DAILY_LIMIT times a UTC day.

It runs the routine with the monitor's own Paperclip key, which can run
only the monitor's routines. Only alert ids go to Paperclip, never alert
text; the monitor reads each alert itself. STATE_DIR/handed.json remembers
what's been handed over, and STATE_DIR/status.json says when a pass last
worked, what last went wrong and when it first ran, for agent-watch. Neither holds a secret.

Environment: PAPERCLIP_URL, ALERTA_URL, STATE_DIR, SEVERITIES and
IGNORE_ORIGINS (comma separated), ROUTINE_TITLE, DAILY_LIMIT, and
CREDENTIALS_DIRECTORY holding paperclip-key and alerta-key.
"""
import datetime
import hashlib
import json
import os
import pathlib
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
# A triage the monitor is still working on.
WORKING = "todo,in_progress"
# Run statuses that mean the alerts are in an issue.
HANDED = {"issue_created", "coalesced", "skipped"}


class Failure(Exception):
    """A pass that didn't work. The message stays the same while the cause
    does, since agent-watch's alert carries it; how many alerts are waiting
    goes apart."""

    def __init__(self, message, waiting=0):
        super().__init__(message)
        self.waiting = waiting


def now():
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)


def iso(moment):
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def credential(name):
    return (pathlib.Path(os.environ["CREDENTIALS_DIRECTORY"]) / name).read_text().strip()


def request(method, url, auth, secrets, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Accept": "application/json", "Authorization": auth,
        **({"Content-Type": "application/json"} if data else {})})
    where = url.split("?")[0]
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as err:
        detail = " ".join(err.read(300).decode(errors="replace").split())
        for secret in secrets:
            detail = detail.replace(secret, "***")
        raise Failure(f"{method} {where} failed: HTTP {err.code} {detail}") from None
    except urllib.error.URLError as err:
        raise Failure(f"cannot reach {where}: {err.reason}") from None


def load(path, default):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return default


def save(path, value):
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(value, indent=1))
    os.chmod(tmp, 0o644)
    tmp.replace(path)


def handover(env, state, moment, paperclip_key, alerta_key):
    """One pass; returns what happened, or raises Failure."""
    secrets = [paperclip_key, alerta_key]
    alerta = env["ALERTA_URL"].rstrip("/")
    paperclip = env.get("PAPERCLIP_URL", "http://127.0.0.1:3100").rstrip("/")
    severities = {s for s in env.get("SEVERITIES", "critical,major,minor,warning").split(",") if s}
    ignore = {s for s in env.get("IGNORE_ORIGINS", "agent-watch").split(",") if s}
    title = env["ROUTINE_TITLE"]
    limit = int(env.get("DAILY_LIMIT", "24"))

    query = urllib.parse.urlencode([("status", "open"), ("page-size", "1000")])
    found = request("GET", f"{alerta}/alerts?{query}", f"Key {alerta_key}", secrets) or {}
    open_ids = sorted({str(a.get("id")) for a in found.get("alerts") or []
                       if UUID.match(str(a.get("id"))) and a.get("severity") in severities
                       and a.get("origin") not in ignore})

    # Forget alerts that closed; a new day starts the count again.
    state["ids"] = {i: t for i, t in state.get("ids", {}).items() if i in open_ids}
    day = moment.strftime("%Y-%m-%d")
    if state.get("day") != day:
        state["day"], state["runs"] = day, 0
    new = [i for i in open_ids if i not in state["ids"]]
    if not new:
        return f"{len(open_ids)} open alert(s), none new"

    def pc(method, path, body=None):
        return request(method, paperclip + path, f"Bearer {paperclip_key}", secrets, body)

    me = pc("GET", "/api/agents/me")
    cid = me["companyId"]
    routine = next((r for r in pc("GET", f"/api/companies/{cid}/routines")
                    if r.get("title") == title and r.get("assigneeAgentId") == me["id"]), None)
    if routine is None:
        raise Failure(f"the monitor has no routine titled {title!r}", len(new))
    if routine.get("status") != "active":
        return f"the triage routine is {routine.get('status')}; {len(new)} new alert(s) wait"
    working = pc("GET", f"/api/companies/{cid}/issues?" + urllib.parse.urlencode(
        [("originKind", "routine_execution"), ("originId", routine["id"]), ("status", WORKING), ("limit", "20")]))
    if working:
        return f"waiting on {working[0].get('identifier', 'an open triage')}; {len(new)} new alert(s) wait"
    if state["runs"] >= limit:
        raise Failure(f"the daily limit of {limit} triage runs is reached", len(new))

    ids = " ".join(new)
    run = pc("POST", f"/api/routines/{routine['id']}/run", {
        "source": "api", "variables": {"count": len(new), "alerts": ids},
        "idempotencyKey": "monitor-intake:" + hashlib.sha256(ids.encode()).hexdigest()[:32]}) or {}
    status = run.get("status")
    if status not in HANDED:
        raise Failure(f"the triage run came back {status}: {run.get('failureReason') or 'no reason given'}", len(new))
    for i in new:
        state["ids"][i] = iso(moment)
    if status == "issue_created":
        state["runs"] += 1
    return f"handed {len(new)} alert(s) to the monitor ({status})"


def main():
    env = os.environ
    state_dir = pathlib.Path(env["STATE_DIR"])
    status_path = state_dir / "status.json"
    status = load(status_path, {"last_ok": None, "last_error": None, "last_error_at": None})
    moment = now()
    status.setdefault("started", iso(moment))
    state_path = state_dir / "handed.json"
    state = load(state_path, {})
    try:
        result = handover(env, state, moment, credential("paperclip-key"), credential("alerta-key"))
    except Failure as err:
        status.update(last_error=str(err), last_error_at=iso(moment), waiting=err.waiting)
        save(status_path, status)
        save(state_path, state)
        sys.exit(f"monitor-intake: {err}" + (f"; {err.waiting} new alert(s) wait" if err.waiting else ""))
    save(state_path, state)
    status.update(last_ok=iso(moment), last_result=result, waiting=0)
    save(status_path, status)
    print(f"monitor-intake: {result}")


if __name__ == "__main__":
    main()
