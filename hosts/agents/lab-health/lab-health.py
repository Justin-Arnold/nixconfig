#!/usr/bin/env python3
"""lab-health: the lab's morning check, in code, waking the monitor only for findings.

One pass, run at 07:00 New York time by a timer on the agents host
(hosts/agents/lab-health.nix):

1. Read Proxmox, Beszel, Kuma and Alerta, each that's set up, with the lab
   MCP server's own functions (LAB_SERVER, imported), so what's asked for,
   which fields are kept and how Proxmox fails over are the agents' own. A
   source that fails, or whose answer was cut short, is one it couldn't read.
2. Turn what's wrong into fixed codes, from the thresholds below:

     not-quorate                        the cluster has lost quorum
     node-offline:<node>                a node is offline, unless EXPECTED_OFFLINE names it
     ha-not-started:<sid>               an HA resource meant to run isn't running
     storage-full:<node>/<storage>:<pct>  STORAGE_PERCENT or more; shared storage once, as shared/<storage>
     storage-unavailable:<node>/<storage>  on a node that's online
     task-failed:<node>:<type>          a Proxmox task failed in the last TASK_HOURS
     system-down:<system>               Beszel can't reach a system's agent
     disk-full:<system>[/<fs>]:<pct>    DISK_PERCENT or more
     memory-high:<system>:<pct>         MEMORY_PERCENT or more
     services-failed:<system>:<n>       systemd units in a failed state
     monitor-down:<name>                a Kuma monitor is down
     alert-stale:<resource>/<event>     an alert the triage would take, open for ALERT_HOURS
     unreadable:<source>                a source it couldn't read

   A code keeps only [A-Za-z0-9 ._:/@-], so nothing a source says reaches
   the monitor as free text.
3. With findings, run the monitor's routine titled ROUTINE_TITLE with the
   monitor's own Paperclip key, which can run only the monitor's routines,
   with the codes and how many there are, keyed on the UTC date, so a day
   starts one issue. With none, start nothing.

STATE_DIR/status.json says when a pass last worked (every source read and
any findings handed over), what last went wrong and what it found, for
agent-watch's HealthStale. It holds no secret.

--dry-run reads and prints, starts nothing and writes nothing, and exits 1
when a source couldn't be read.

Environment: LAB_SERVER, the lab server's settings (PROXMOX_URLS,
PROXMOX_CA, BESZEL_URL, BESZEL_USER, KUMA_URL, KUMA_SLUG, ALERTA_URL),
PAPERCLIP_URL, ROUTINE_TITLE, STATE_DIR, STORAGE_PERCENT (85), DISK_PERCENT
(85), MEMORY_PERCENT (90), TASK_HOURS (24), ALERT_HOURS (24),
EXPECTED_OFFLINE, INTAKE_SEVERITIES, INTAKE_IGNORE_ORIGINS and
INTAKE_HARMLESS (comma separated, the alert intake's own rules), and
CREDENTIALS_DIRECTORY holding paperclip-key, and proxmox-token,
beszel-password and alerta-key for the sources that are set up.
"""
import datetime
import importlib.util
import json
import os
import pathlib
import re
import sys

# Each credential, and the lab server's variable it goes in.
SOURCE_KEYS = {"proxmox-token": "PROXMOX_TOKEN", "beszel-password": "BESZEL_PASSWORD", "alerta-key": "ALERTA_KEY"}
# HA states a resource passes through on its way to running somewhere.
MOVING = {"started", "migrate", "relocate"}


def now():
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)


def iso(moment):
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def when(value):
    try:
        return datetime.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None


def part(value):
    """One piece of a code: the characters a code may hold, at most 64."""
    return re.sub(r"[^A-Za-z0-9 ._:/@-]", "_", str(value)).strip()[:64] or "_"


def code(*parts):
    return ":".join(part(p) for p in parts)


def split(name):
    return {v for v in os.environ.get(name, "").split(",") if v}


def number(name, default):
    return float(os.environ.get(name) or default)


def load_server(path):
    spec = importlib.util.spec_from_file_location("lab_server", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def proxmox_findings(lab, moment, seen):
    found = []
    cluster = lab.proxmox_cluster()
    if (cluster.get("cluster") or {}).get("quorate") == 0:
        found.append("not-quorate")
    expected = split("EXPECTED_OFFLINE")
    online = {n.get("name") for n in cluster.get("nodes") or [] if n.get("online") == 1}
    seen["nodes"] = sorted(online)
    for node in cluster.get("nodes") or []:
        if node.get("online") != 1 and node.get("name") not in expected:
            found.append(code("node-offline", node.get("name")))
    for resource in cluster.get("ha") or []:
        if (resource.get("type") == "service" and resource.get("request_state") == "started"
                and resource.get("state") not in MOVING):
            found.append(code("ha-not-started", str(resource.get("id", "")).removeprefix("service:")))

    limit = number("STORAGE_PERCENT", 85)
    shared = {}
    for store in sorted(lab.proxmox_resources("storage")["items"], key=lambda s: (s.get("storage", ""), s.get("node", ""))):
        node, name = store.get("node"), store.get("storage")
        if node not in online:
            continue  # its node is offline, or not in the cluster's list: node-offline says so
        where = f"shared/{name}" if store.get("shared") else f"{node}/{name}"
        if store.get("status") != "available":
            found.append(code("storage-unavailable", where))
        elif store.get("maxdisk"):
            pct = int(store.get("disk", 0) * 100 // store["maxdisk"])
            if pct >= limit:
                if store.get("shared"):
                    shared.setdefault(name, code("storage-full", where, pct))
                else:
                    found.append(code("storage-full", where, pct))
    found += shared.values()

    since = (moment - datetime.timedelta(hours=number("TASK_HOURS", 24))).timestamp()
    for task in lab.proxmox("/cluster/tasks") or []:
        status = str(task.get("status") or "")
        # Running tasks have no status yet; warnings aren't failures.
        if status and status != "OK" and not status.startswith("WARNINGS") and (task.get("endtime") or 0) >= since:
            found.append(code("task-failed", task.get("node"), task.get("type")))
    return found


def beszel_findings(lab):
    found = []
    disk, memory = number("DISK_PERCENT", 85), number("MEMORY_PERCENT", 90)
    for system in lab.beszel_systems()["systems"]:
        name, info = system.get("name"), system.get("info") or {}
        if system.get("status") == "down":
            found.append(code("system-down", name))
            continue
        if system.get("status") != "up":
            continue  # paused, or still connecting
        if float(info.get("dp") or 0) >= disk:
            found.append(code("disk-full", name, int(info["dp"])))
        for fs, pct in sorted((info.get("efs") or {}).items()):
            if float(pct or 0) >= disk:
                found.append(code("disk-full", f"{name}/{fs}", int(pct)))
        if float(info.get("mp") or 0) >= memory:
            found.append(code("memory-high", name, int(info["mp"])))
        services = info.get("sv") or []
        if len(services) > 1 and services[1]:
            found.append(code("services-failed", name, services[1]))
    return found


class CutShort(Exception):
    pass


def kuma_findings(lab):
    monitors = lab.kuma_monitors()
    if monitors.get("truncated"):
        raise CutShort("Kuma's list was cut short")
    return [code("monitor-down", m.get("name")) for m in monitors["monitors"] if m.get("state") == "down"]


def alerta_findings(lab, moment):
    """Alerts the triage would take that have been open ALERT_HOURS, so the
    agents' own alerts, n8n's and known-harmless ones don't count."""
    answer = lab.alerta("/alerts", {"status": "open", "environment": "Homelab", "page-size": 1000})
    alerts = answer.get("alerts") or []
    if (answer.get("total") or 0) > len(alerts):
        raise CutShort(f"Alerta gave {len(alerts)} of {answer.get('total')} open alerts")
    severities, ignore, harmless = split("INTAKE_SEVERITIES"), split("INTAKE_IGNORE_ORIGINS"), split("INTAKE_HARMLESS")
    before = moment - datetime.timedelta(hours=number("ALERT_HOURS", 24))
    found = []
    for a in alerts:
        opened = when(a.get("receiveTime") or a.get("createTime"))
        if (a.get("severity") in severities and a.get("origin") not in ignore
                and f"{a.get('origin')}/{a.get('event')}" not in harmless and opened is not None and opened < before):
            found.append(code("alert-stale", f"{a.get('resource')}/{a.get('event')}"))
    return found


def check(lab, moment):
    """(sources read, nodes online, findings, what couldn't be read)."""
    seen = {}
    readers = {"proxmox": lambda: proxmox_findings(lab, moment, seen), "beszel": lambda: beszel_findings(lab),
               "kuma": lambda: kuma_findings(lab), "alerta": lambda: alerta_findings(lab, moment)}
    read, findings, problems = [], [], []
    for source in lab.enabled_sources():
        try:
            findings += readers[source]()
            read.append(source)
        except (lab.Refused, CutShort, KeyError, TypeError, ValueError, AttributeError) as err:
            findings.append(code("unreadable", source))
            problems.append(f"{source}: {lab.scrub(str(err))[:200]}")
    return read, seen.get("nodes", []), sorted(set(findings)), problems


def hand_over(lab, findings, moment, key):
    """Runs the monitor's findings routine; returns what happened."""
    base = os.environ.get("PAPERCLIP_URL", "http://127.0.0.1:3100").rstrip("/")
    auth = {"Authorization": f"Bearer {key}"}

    def pc(method, path, body=None):
        try:
            return lab.request(method, base + path, auth, body)
        except lab.Refused as err:
            raise lab.Refused(str(err).replace(key, "***")) from None

    title = os.environ["ROUTINE_TITLE"]
    me = pc("GET", "/api/agents/me")
    routine = next((r for r in pc("GET", f"/api/companies/{me['companyId']}/routines")
                    if r.get("title") == title and r.get("assigneeAgentId") == me["id"]), None)
    if routine is None:
        raise lab.Refused(f"the monitor has no routine titled {title!r}")
    if routine.get("status") != "active":
        return f"the findings routine is {routine.get('status')}, so nothing was started"
    run = pc("POST", f"/api/routines/{routine['id']}/run", {
        "source": "api", "variables": {"count": len(findings), "findings": "; ".join(findings)},
        "idempotencyKey": f"lab-health:{moment:%Y-%m-%d}"}) or {}
    status = run.get("status")
    if status not in ("issue_created", "coalesced", "skipped"):
        raise lab.Refused(f"the findings run came back {status}: {run.get('failureReason') or 'no reason given'}")
    return f"handed {len(findings)} finding(s) to the monitor ({status})"


def save(path, value):
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(value, indent=1))
    os.chmod(tmp, 0o644)
    tmp.replace(path)


def main():
    dry = sys.argv[1:] == ["--dry-run"]
    if sys.argv[1:] not in ([], ["--dry-run"]):
        sys.exit("usage: lab-health.py [--dry-run]")
    creds = pathlib.Path(os.environ["CREDENTIALS_DIRECTORY"])
    for name, var in SOURCE_KEYS.items():
        if (creds / name).exists():
            os.environ[var] = (creds / name).read_text().strip()
    lab = load_server(os.environ["LAB_SERVER"])
    moment = now()

    read, nodes, findings, problems = check(lab, moment)
    print(f"lab-health: read {', '.join(read) or 'nothing'}"
          + (f"; couldn't read {'; '.join(problems)}" if problems else ""))
    if nodes:
        print(f"lab-health: online nodes {' '.join(nodes)}")
    print(f"lab-health: {len(findings)} finding(s)" + (f": {'; '.join(findings)}" if findings else ""))
    if dry:
        sys.exit(1 if problems else 0)

    state = pathlib.Path(os.environ["STATE_DIR"]) / "status.json"
    try:
        status = json.loads(state.read_text())
    except (FileNotFoundError, ValueError):
        status = {}
    status.setdefault("started", iso(moment))
    status.update(last_run=iso(moment), findings=findings)
    error = "couldn't read " + "; ".join(problems) if problems else None
    if findings:
        try:
            result = hand_over(lab, findings, moment, (creds / "paperclip-key").read_text().strip())
        except lab.Refused as err:
            result, error = None, (error + "; " if error else "") + str(err)
    else:
        result = "nothing to hand over"
    if result:
        print(f"lab-health: {result}")
        status["last_result"] = result
    if error:
        status.update(last_error=error, last_error_at=iso(moment))
        save(state, status)
        sys.exit(f"lab-health: {error}")
    status["last_ok"] = iso(moment)
    save(state, status)


if __name__ == "__main__":
    main()
