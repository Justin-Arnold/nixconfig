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
  MarkedChange,    an open issue carries the change or sensitive label
  MarkedSensitive  (warning)
  BudgetWarning    a budget is past its warning level (warning) or stopped
                   (major)

Every pass sends each alert that still holds. Alerta counts a repeat as a
duplicate and the forwarder only notifies on a change, so a text never
carries anything that moves on its own, like a duration. Alerts it raised
earlier that no longer hold are cleared; it finds them by asking Alerta for
its open ones, so it keeps no state. After a good pass it reports to Kuma's
push URL, so Kuma notices when it stops.

Environment: PAPERCLIP_URL, ALERTA_URL, STUCK_AFTER_MINUTES (60), and
CREDENTIALS_DIRECTORY holding paperclip-key, alerta-key and kuma-push-url.
"""
import datetime
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


def alert(resource, event, severity, title, text):
    return {
        "environment": ENVIRONMENT,
        "resource": f"paperclip/{resource}",
        "event": event,
        "severity": severity,
        "service": ["Paperclip"],
        "group": "Agents",
        "origin": ORIGIN,
        "tags": [ORIGIN],
        "text": text,
        "attributes": {"notificationTitle": title},
    }


def watch(get, stuck_after, now):
    """Every alert that holds right now."""
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
                            f"Waiting on you: {what}" + (f": {short(name)}" if name else ".")))

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


def main():
    paperclip = os.environ.get("PAPERCLIP_URL", "http://127.0.0.1:3100").rstrip("/")
    alerta = os.environ["ALERTA_URL"].rstrip("/")
    stuck_after = datetime.timedelta(minutes=int(os.environ.get("STUCK_AFTER_MINUTES", "60")))
    paperclip_auth = {"Authorization": f"Bearer {credential('paperclip-key')}"}
    alerta_auth = {"Authorization": f"Key {credential('alerta-key')}"}

    def get(path):
        return request("GET", paperclip + path, paperclip_auth)

    alerts = watch(get, stuck_after, datetime.datetime.now(datetime.timezone.utc))
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
                "severity": "cleared", "service": ["Paperclip"], "group": "Agents", "origin": ORIGIN,
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
