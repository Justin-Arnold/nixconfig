#!/usr/bin/env python3
"""agent-watch: raise and clear Alerta alerts from what Paperclip shows.

One pass, run by a timer on the agents host (hosts/agents/agent-watch.nix).
It reads Paperclip with an agent key and keeps these alerts in Alerta
(environment Homelab, origin agent-watch, resource paperclip/<what>), which
the forwarder on lab118-services sends to the phone:

  RunFailed        an agent is in error, or its last finished run failed or
                   timed out (minor)
  IssueStuck       an issue is in progress with no run and no activity for
                   STUCK_AFTER_MINUTES (warning)
  ApprovalWaiting  an approval waits on the board (warning)
  WaitingOnYou     an open issue has a question for the board, or is blocked
                   on the board (warning)
  MarkedChange,    an open issue carries the change or sensitive label
  MarkedSensitive  (warning)
  BudgetWarning    a budget is past its warning level (warning) or stopped
                   (major)

and, from what agent-costs writes for each agent (COSTS_DIR/<agent>/
month.json), alerts about the money behind them (resource anthropic/credits
or typesafe/credits):

  ClaudeSpend      this month's estimated Claude spend across the agents has
                   passed CLAUDE_WARN_PERCENT of CLAUDE_MONTHLY_CREDITS
                   dollars (warning), or all of it (major)
  ClaudeCreditsOut Claude refused an agent for credits, and it hasn't worked
                   for that agent since (major); the agent is on its fallback
  JevCreditsOut    the same for Jev (major); agents carry on without it

and, from monitor-intake's INTAKE_STATUS file (resource
agents/monitor-intake):

  IntakeStale      monitor-intake hasn't handed new alerts to the monitor
                   for INTAKE_STALE_MINUTES, with the reason it last gave
                   (warning)

and, from board-bridge's BRIDGE_STATUS file (resource agents/board-bridge):

  BridgeStale      board-bridge hasn't read Paperclip and reached every chat
                   channel that's on for BRIDGE_STALE_MINUTES, with the
                   reason it last gave (warning)

and, from paperclip-events' EVENTS_STATUS file (resource
agents/paperclip-events):

  EventsStale      paperclip-events hasn't been connected to Paperclip's
                   live events for EVENTS_STALE_MINUTES, so nothing on this
                   host reacts until its timers come round, with the reason
                   it last gave (warning)

Alerts about one issue or approval carry a link to it in Paperclip
(attributes.url, under PAPERCLIP_LINK), which the forwarder puts on the
phone.

Every pass sends each alert that still holds. Alerta counts a repeat as a
duplicate and the forwarder only notifies on a change, so a text never
carries anything that moves on its own, like a duration. Alerts it raised
earlier that no longer hold are cleared; it finds them by asking Alerta for
its open ones, so it keeps no state. After a good pass it reports to Kuma's
push URL, so Kuma notices when it stops.

Environment: PAPERCLIP_URL, PAPERCLIP_LINK (the board's public URL and the
company's prefix, as https://<host>/LAB), ALERTA_URL, STUCK_AFTER_MINUTES
(60), COSTS_DIR, CLAUDE_MONTHLY_CREDITS (100), CLAUDE_WARN_PERCENT (80),
INTAKE_STATUS, INTAKE_STALE_MINUTES (15), BRIDGE_STATUS,
BRIDGE_STALE_MINUTES (15), EVENTS_STATUS, EVENTS_STALE_MINUTES (5), and
CREDENTIALS_DIRECTORY holding paperclip-key, alerta-key and kuma-push-url.
"""
import datetime
import glob
import json
import os
import pathlib
import sys
import urllib.error
import urllib.parse
import urllib.request

ORIGIN = "agent-watch"
ENVIRONMENT = "Homelab"
FINISHED = {"succeeded", "failed", "timed_out", "cancelled", "interrupted"}
FAILED = {"failed", "timed_out"}
OPEN_ISSUE = "backlog,todo,in_progress,in_review,blocked"
# Where a question for the board can be waiting.
ASKING_ISSUE = "todo,in_progress,in_review,blocked"
APPROVALS = {
    "hire_agent": "a new agent",
    "approve_ceo_strategy": "the coordinator's strategy",
    "budget_override_required": "a budget override",
    "request_board_approval": "a request for approval",
}


def credential(name):
    return (pathlib.Path(os.environ["CREDENTIALS_DIRECTORY"]) / name).read_text().strip()


def request(method, url, headers, body=None, name=None):
    """JSON from url. Errors name the URL without its query, or name instead."""
    name = name or url.split("?")[0]
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method, headers={"Accept": "application/json", **headers})
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as err:
        detail = err.read().decode(errors="replace")[:300]
        sys.exit(f"{method} {name} failed: HTTP {err.code} {detail}")
    except urllib.error.URLError as err:
        sys.exit(f"cannot reach {name}: {err.reason}")
    try:
        return json.loads(raw) if raw else None
    except ValueError:
        sys.exit(f"{method} {name} answered with something that isn't JSON: {short(raw.decode(errors='replace'), 120)}")


def when(value):
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00")) if value else None


def short(text, limit=200):
    text = " ".join(str(text).split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


def alert(resource, event, severity, title, text, service="Paperclip", url=None):
    return {
        "environment": ENVIRONMENT,
        "resource": resource if "/" in resource else f"paperclip/{resource}",
        "event": event,
        "severity": severity,
        "service": [service],
        "group": "Agents",
        "origin": ORIGIN,
        "tags": [ORIGIN],
        "text": text,
        "attributes": {"notificationTitle": title, **({"url": url} if url else {})},
    }


def question(interaction):
    """What an interaction asks, in a line."""
    payload = interaction.get("payload") or {}
    questions = payload.get("questions") or []
    return (interaction.get("title") or payload.get("title")
            or (questions[0].get("prompt") if questions else None) or payload.get("prompt")
            or (interaction.get("kind") or "a question").replace("_", " "))


def watch(get, stuck_after, now, link=None):
    """Every alert that holds right now. link is PAPERCLIP_LINK, or None."""
    cid = get("/api/agents/me")["companyId"]
    base = f"/api/companies/{cid}"
    alerts = []

    for agent in get(f"{base}/agents"):
        runs = get(f"{base}/heartbeat-runs?agentId={agent['id']}&limit=20")
        last = next((r for r in runs if r.get("status") in FINISHED), None)
        failed = last is not None and last["status"] in FAILED
        if agent.get("status") == "error" or failed:
            reason = (last or {}).get("error") or (last or {}).get("errorCode") or agent.get("errorReason")
            what = f"its last run {last['status'].replace('_', ' ')}" if failed else "it's in error"
            alerts.append(alert(agent["name"].lower(), "RunFailed", "minor", f"Paperclip: {agent['name']} failed",
                                f"{agent['name']}: {what}" + (f": {short(reason)}" if reason else ".")))

    for issue in get(f"{base}/issues?status=in_progress&limit=1000"):
        last = when(issue.get("lastActivityAt") or issue.get("updatedAt"))
        if issue.get("activeRun") is None and last is not None and now - last > stuck_after:
            alerts.append(alert(issue["identifier"], "IssueStuck", "warning", f"Paperclip: {issue['identifier']} is stuck",
                                f"{issue['identifier']} has been in progress with no run since "
                                f"{last:%Y-%m-%d %H:%M} UTC: {short(issue['title'])}"))

    for approval in get(f"{base}/approvals?status=pending"):
        payload = approval.get("payload") or {}
        name = payload.get("title") or payload.get("name") or payload.get("summary")
        what = APPROVALS.get(approval.get("type"), approval.get("type") or "an approval")
        alerts.append(alert(f"approval-{approval['id'][:8]}", "ApprovalWaiting", "warning", "Paperclip: approval waiting",
                            f"Waiting on you: {what}" + (f": {short(name)}" if name else "."),
                            url=link and f"{link}/approvals/{approval['id']}"))

    # A question or confirmation the board hasn't answered, or an issue left
    # blocked on the board, which only the board itself can do (Paperclip
    # refuses agents that name it). Issues blocked on other issues don't count.
    for issue in get(f"{base}/issues?status={ASKING_ISSUE}&limit=1000"):
        pending = sorted((i for i in get(f"/api/issues/{issue['id']}/interactions") or [] if i.get("status") == "pending"),
                         key=lambda i: i.get("createdAt") or "")
        descriptor = issue.get("unblockDescriptor") or {}
        if pending:
            text = f"{issue['identifier']} asks: {short(question(pending[0]))}"
        elif issue.get("status") == "blocked" and descriptor.get("owner") == "board":
            text = f"{issue['identifier']} waits on you: {short(descriptor.get('action') or issue['title'])}"
        else:
            continue
        alerts.append(alert(issue["identifier"], "WaitingOnYou", "warning", f"Paperclip: {issue['identifier']} needs you",
                            text, url=link and f"{link}/issues/{issue['identifier']}"))

    labels = {label["name"]: label["id"] for label in get(f"{base}/labels")}
    for label, event in (("change", "MarkedChange"), ("sensitive", "MarkedSensitive")):
        if label not in labels:
            continue
        for issue in get(f"{base}/issues?labelId={labels[label]}&status={OPEN_ISSUE}&limit=1000"):
            alerts.append(alert(issue["identifier"], event, "warning", f"Paperclip: {issue['identifier']} is marked {label}",
                                f"{issue['identifier']} is marked {label}: {short(issue['title'])}"))

    for policy in get(f"{base}/budgets/overview").get("policies") or []:
        status = policy.get("status")
        if status not in ("warning", "hard_stop"):
            continue
        scope = policy.get("scopeName") or policy.get("scopeType") or "company"
        alerts.append(alert(f"budget-{str(policy.get('id', scope))[:8]}", "BudgetWarning",
                            "major" if status == "hard_stop" else "warning", f"Paperclip: {scope} budget",
                            f"The {scope} budget is " + ("stopped" if status == "hard_stop" else "past its warning level")
                            + f" ({policy.get('warnPercent')}% warns)."))
    return alerts


def credits(costs_dir, monthly_dollars, warn_percent, now):
    """The credit alerts, from each agent's month.json. A file that can't be
    read is skipped: spend reporting failing shouldn't stop the other alerts."""
    month = now.strftime("%Y-%m")
    files = {}
    for path in sorted(glob.glob(os.path.join(costs_dir, "*", "month.json"))):
        try:
            data = json.loads(pathlib.Path(path).read_text())
        except (OSError, ValueError):
            print(f"skipping {path}: unreadable")
            continue
        files[data.get("agent") or pathlib.Path(path).parent.name] = data
    alerts = []

    spent = sum(float(d["claude"]["cents"]) for d in files.values() if d.get("month") == month) / 100
    if spent >= monthly_dollars * warn_percent / 100:
        full = spent >= monthly_dollars
        # The threshold, not the amount, so the text doesn't change every pass.
        alerts.append(alert("anthropic/credits", "ClaudeSpend", "major" if full else "warning", "Claude credits",
                            (f"The agents' estimated Claude spend this month has passed the ${monthly_dollars} of credit."
                             if full else f"The agents' estimated Claude spend this month has passed {warn_percent}% "
                             f"of the ${monthly_dollars} of credit."), service="Agents"))

    for provider, event, resource, name, after in (
            ("claude", "ClaudeCreditsOut", "anthropic/credits", "Claude", "they're on their fallback models"),
            ("jev", "JevCreditsOut", "typesafe/credits", "Jev", "they're carrying on without it")):
        out = sorted(agent for agent, d in files.items()
                     if (d.get(provider) or {}).get("last_refused")
                     and (d[provider]["last_refused"] > ((d[provider].get("last_ok")) or "")))
        if out:
            alerts.append(alert(resource, event, "major", f"{name} credits ran out",
                                f"{name} refused {', '.join(out)} for credits, so {after}. Top up the {name} credits.",
                                service="Agents"))
    return alerts


def stale(status_file, stale_after, now, resource, event, title, what):
    """event, when a service that writes a status.json (last_ok, last_error,
    last_error_at, started) hasn't had a good pass for stale_after. Before
    its first pass, it counts from when the service started, or when its
    folder was made. what says what's stopped, as "<service> hasn't ..."."""
    path = pathlib.Path(status_file)
    try:
        status = json.loads(path.read_text())
    except FileNotFoundError:
        status = {}
    except (OSError, ValueError):
        status = {"last_error": "its status file can't be read"}
    since = when(status.get("last_ok")) or when(status.get("started"))
    if since is None:
        try:
            since = datetime.datetime.fromtimestamp(path.parent.stat().st_mtime, datetime.timezone.utc)
        except OSError:
            pass
    if since is not None and now - since <= stale_after:
        return []
    last_ok = status.get("last_ok")
    error = status.get("last_error")
    if error and last_ok and (status.get("last_error_at") or "") < last_ok:
        error = None
    text = (f"{what} since "
            + (f"{when(last_ok):%Y-%m-%d %H:%M} UTC" if last_ok else "it was set up")
            + (f": {short(error)}" if error else "."))
    return [alert(resource, event, "warning", title, text, service="Agents")]


def main():
    paperclip = os.environ.get("PAPERCLIP_URL", "http://127.0.0.1:3100").rstrip("/")
    alerta = os.environ["ALERTA_URL"].rstrip("/")
    stuck_after = datetime.timedelta(minutes=int(os.environ.get("STUCK_AFTER_MINUTES", "60")))
    paperclip_auth = {"Authorization": f"Bearer {credential('paperclip-key')}"}
    alerta_auth = {"Authorization": f"Key {credential('alerta-key')}"}

    def get(path):
        return request("GET", paperclip + path, paperclip_auth)

    now = datetime.datetime.now(datetime.timezone.utc)
    alerts = watch(get, stuck_after, now, os.environ.get("PAPERCLIP_LINK", "").rstrip("/") or None)
    if os.environ.get("COSTS_DIR"):
        alerts += credits(os.environ["COSTS_DIR"], int(os.environ.get("CLAUDE_MONTHLY_CREDITS", "100")),
                          int(os.environ.get("CLAUDE_WARN_PERCENT", "80")), now)
    if os.environ.get("INTAKE_STATUS"):
        alerts += stale(os.environ["INTAKE_STATUS"],
                        datetime.timedelta(minutes=int(os.environ.get("INTAKE_STALE_MINUTES", "15"))), now,
                        "agents/monitor-intake", "IntakeStale", "Alert intake stalled",
                        "monitor-intake hasn't handed new alerts to the monitor")
    if os.environ.get("BRIDGE_STATUS"):
        alerts += stale(os.environ["BRIDGE_STATUS"],
                        datetime.timedelta(minutes=int(os.environ.get("BRIDGE_STALE_MINUTES", "15"))), now,
                        "agents/board-bridge", "BridgeStale", "Board bridge stalled",
                        "board-bridge hasn't had a good pass")
    if os.environ.get("EVENTS_STATUS"):
        alerts += stale(os.environ["EVENTS_STATUS"],
                        datetime.timedelta(minutes=int(os.environ.get("EVENTS_STALE_MINUTES", "5"))), now,
                        "agents/paperclip-events", "EventsStale", "Paperclip events lost",
                        "paperclip-events hasn't been connected")
    wanted = {(a["resource"], a["event"]) for a in alerts}

    query = urllib.parse.urlencode([("environment", ENVIRONMENT), ("origin", ORIGIN),
                                    ("status", "open"), ("status", "ack"), ("page-size", "1000")])
    raised = request("GET", f"{alerta}/alerts?{query}", alerta_auth).get("alerts") or []
    cleared = 0
    for old in raised:
        if (old["resource"], old["event"]) not in wanted:
            cleared += 1
            request("POST", f"{alerta}/alert", alerta_auth, {
                "environment": ENVIRONMENT, "resource": old["resource"], "event": old["event"],
                "severity": "cleared", "service": old.get("service") or ["Paperclip"], "group": "Agents", "origin": ORIGIN,
                "tags": [ORIGIN], "text": "Resolved.",
                "attributes": {"notificationTitle": (old.get("attributes") or {}).get("notificationTitle", old["resource"])},
            })
    for new in alerts:
        request("POST", f"{alerta}/alert", alerta_auth, new)

    summary = f"{len(alerts)} alert(s) held, {cleared} cleared"
    print(summary)
    # Kuma's copy-paste URL already carries ?status=up&msg=OK&ping=; drop it.
    # Its path is the push token, so errors give only the host.
    push = credential("kuma-push-url").split("?")[0]
    host = urllib.parse.urlsplit(push).netloc
    request("GET", f"{push}?{urllib.parse.urlencode({'status': 'up', 'msg': summary})}", {},
            name=f"the Kuma push URL on {host}")


if __name__ == "__main__":
    main()
