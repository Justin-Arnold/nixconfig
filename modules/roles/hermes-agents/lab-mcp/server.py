#!/usr/bin/env python3
"""The lab's state, read-only, as MCP tools for a Hermes agent.

Hermes starts this over stdio. It reads four sources, each only when its
settings are in the environment, and never changes anything:

  Proxmox  the cluster, nodes, guests, storage, HA and failed tasks, with an
           API token that can only audit
             PROXMOX_URLS   one or more node URLs (https://<node>:8006), tried
                            in turn, so one node being down doesn't matter
             PROXMOX_CA     the cluster's CA certificate, to trust its nodes
             PROXMOX_TOKEN  <user>@<realm>!<id>=<secret>
  Beszel   systems, their latest stats and systemd services, as a readonly
           user
             BESZEL_URL, BESZEL_USER, BESZEL_PASSWORD
  Kuma     each monitor's state, from a status page made for the agents
             KUMA_URL, KUMA_SLUG
  Alerta   alerts and their history, with a key that can only read
             ALERTA_URL (the API itself, not the web UI), ALERTA_KEY

Every request is a GET to a fixed path, except Beszel's login. Nothing asks
for VM configs, task logs, firewall or access settings, Beszel's agent
fingerprints or anyone's settings. Plain HTTP is allowed only to the lab
tunnel (10.118.0.0/24) and loopback. LAB_CALL_LOG, when set, gets one line
per call with its id, tool and outcome, never what came back.
"""
import datetime
import ipaddress
import json
import os
import re
import secrets
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

DEADLINE = 20.0
MAX_RESULT_CHARS = 40_000
TUNNEL = ipaddress.ip_network("10.118.0.0/24")
NODE = re.compile(r"[a-z0-9][a-z0-9-]{0,62}")
SYSTEM = re.compile(r"[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}")
ALERT_ID = re.compile(r"[0-9a-f][0-9a-f-]{7,35}")
RESOURCE_TYPES = {"node", "vm", "storage"}
ALERT_STATUSES = {"open", "ack", "closed", "shelved", "expired"}
SEVERITIES = {"critical", "major", "minor", "warning", "indeterminate", "informational", "normal", "ok", "cleared"}
# Beszel collections a readonly user may be asked for. fingerprints holds each
# system's agent token, and user_settings notification URLs.
BESZEL_COLLECTIONS = {"systems", "system_stats", "systemd_services"}
KUMA_STATES = {0: "down", 1: "up", 2: "pending", 3: "maintenance"}


class Refused(Exception):
    """A call this tool won't make, or an answer it couldn't get."""


def env(name):
    return os.environ.get(name, "").strip()


def secret_values():
    return [v for v in (env("PROXMOX_TOKEN"), env("BESZEL_PASSWORD"), env("ALERTA_KEY"), _beszel.get("token")) if v]


def scrub(text):
    for value in secret_values():
        text = text.replace(value, "***")
        # The token's secret half on its own, too.
        if "=" in value:
            text = text.replace(value.rsplit("=", 1)[1], "***")
    return " ".join(text.split())


def check_url(url, what):
    parts = urllib.parse.urlsplit(url)
    if parts.scheme == "https" and parts.hostname:
        return
    if parts.scheme == "http" and parts.hostname:
        try:
            address = ipaddress.ip_address(parts.hostname)
        except ValueError:
            address = None
        if parts.hostname == "localhost" or (address and (address.is_loopback or address in TUNNEL)):
            return
    raise Refused(f"{what} must be HTTPS, or HTTP to the lab tunnel, not {url}")


def request(method, url, headers, body=None, context=None, deadline=None):
    """The JSON answer, or Refused with the status and a scrubbed reason."""
    left = (deadline or time.monotonic() + DEADLINE) - time.monotonic()
    if left <= 0.5:
        raise Refused(f"no answer within {DEADLINE:.0f} s")
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Accept": "application/json", "User-Agent": "lab-observe-mcp/1",
        **({"Content-Type": "application/json"} if data else {}), **headers})
    try:
        with urllib.request.urlopen(req, timeout=left, context=context) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as err:
        detail = scrub(err.read(1000).decode("utf-8", "replace"))[:200]
        raise Refused(f"HTTP {err.code} from {urllib.parse.urlsplit(url).netloc}: {detail}") from None
    except (urllib.error.URLError, TimeoutError, OSError) as err:
        raise Refused(f"couldn't reach {urllib.parse.urlsplit(url).netloc}: {scrub(str(getattr(err, 'reason', err)))}") from None
    except ValueError:
        raise Refused(f"{urllib.parse.urlsplit(url).netloc} didn't answer with JSON") from None


def pick(record, keys):
    return {k: record[k] for k in keys if isinstance(record, dict) and k in record}


def fit(result):
    """result, with its longest list cut until it fits the size limit."""
    text = json.dumps(result, ensure_ascii=False)
    while len(text) > MAX_RESULT_CHARS:
        lists = [(k, v) for k, v in result.items() if isinstance(v, list) and v]
        if not lists:
            break
        key, items = max(lists, key=lambda kv: len(json.dumps(kv[1])))
        result[key] = items[: max(0, len(items) * 3 // 4)]
        result["truncated"] = True
        text = json.dumps(result, ensure_ascii=False)
    return result


# -- Proxmox ------------------------------------------------------------------

def proxmox(path, params=None):
    token = env("PROXMOX_TOKEN").removeprefix("PVEAPIToken=")
    urls = [u.strip().rstrip("/") for u in env("PROXMOX_URLS").split(",") if u.strip()]
    if not token or not urls:
        raise Refused("Proxmox isn't set up (PROXMOX_URLS, PROXMOX_TOKEN)")
    cafile = env("PROXMOX_CA") or None
    context = None
    if cafile:
        context = ssl.create_default_context(cafile=cafile)
        # Proxmox's cluster CA has no key usage extension, which Python's
        # strict X.509 checks (on by default since 3.13) refuse. The chain
        # and the node's name or address are still verified.
        context.verify_flags &= ~ssl.VERIFY_X509_STRICT
    query = f"?{urllib.parse.urlencode(params)}" if params else ""
    deadline = time.monotonic() + DEADLINE
    errors = []
    for base in urls:
        check_url(base, "PROXMOX_URLS")
        try:
            answer = request("GET", f"{base}/api2/json{path}{query}", {"Authorization": f"PVEAPIToken={token}"},
                             context=context, deadline=deadline)
            return answer.get("data") if isinstance(answer, dict) else None
        except Refused as err:
            message = str(err)
            # Another node can answer for the cluster when this one is down or
            # failing; a refused token or a bad path won't do better elsewhere.
            code = re.search(r"HTTP (\d{3})", message)
            if code and 400 <= int(code.group(1)) < 500 and int(code.group(1)) not in (408, 429):
                raise
            errors.append(message)
    raise Refused("no Proxmox node answered: " + "; ".join(errors))


def proxmox_cluster():
    status = proxmox("/cluster/status") or []
    ha = proxmox("/cluster/ha/status/current") or []
    cluster = next((pick(s, ["name", "quorate", "nodes", "version"]) for s in status if s.get("type") == "cluster"), {})
    nodes = [pick(s, ["name", "online", "ip", "local"]) for s in status if s.get("type") == "node"]
    return {"cluster": cluster, "nodes": nodes,
            "ha": [pick(h, ["id", "type", "status", "state", "node", "crm_state", "request_state"]) for h in ha]}


RESOURCE_FIELDS = {
    "node": ["node", "status", "cpu", "maxcpu", "mem", "maxmem", "disk", "maxdisk", "uptime"],
    "vm": ["vmid", "name", "node", "type", "status", "template", "hastate", "cpu", "maxcpu", "mem", "maxmem",
           "disk", "maxdisk", "uptime", "tags"],
    "storage": ["storage", "node", "status", "plugintype", "shared", "content", "disk", "maxdisk"],
}


def proxmox_resources(kind):
    if kind not in RESOURCE_TYPES:
        raise Refused(f"type must be one of {', '.join(sorted(RESOURCE_TYPES))}")
    items = proxmox("/cluster/resources", {"type": kind}) or []
    return {"type": kind, "items": [pick(r, RESOURCE_FIELDS[kind]) for r in items]}


def check_node(node):
    if not isinstance(node, str) or not NODE.fullmatch(node):
        raise Refused("node is a Proxmox node name, like proxmox4")
    return node


def proxmox_node(node):
    status = proxmox(f"/nodes/{check_node(node)}/status") or {}
    out = pick(status, ["uptime", "loadavg", "cpu", "wait", "pveversion", "kversion"])
    out["cpuinfo"] = pick(status.get("cpuinfo") or {}, ["model", "cpus", "sockets", "cores"])
    for part in ("memory", "swap", "rootfs"):
        out[part] = pick(status.get(part) or {}, ["used", "total", "free", "avail"])
    return {"node": node, **out}


def proxmox_guest(node, vmid):
    node = check_node(node)
    if not isinstance(vmid, int) or isinstance(vmid, bool) or not 100 <= vmid <= 999_999_999:
        raise Refused("vmid is a number from 100 up")
    fields = ["vmid", "name", "status", "qmpstatus", "lock", "cpu", "cpus", "mem", "maxmem", "disk", "maxdisk",
              "netin", "netout", "diskread", "diskwrite", "uptime", "ha", "template"]
    for kind in ("qemu", "lxc"):
        try:
            status = proxmox(f"/nodes/{node}/{kind}/{vmid}/status/current")
        except Refused as err:
            # A VM's id asked for as a container, or the other way round,
            # answers 500 "does not exist".
            if "does not exist" in str(err):
                continue
            raise
        return {"node": node, "kind": kind, **pick(status or {}, fields)}
    raise Refused(f"no VM or container {vmid} on {node}")


def proxmox_failed_tasks(limit=20):
    if not isinstance(limit, int) or isinstance(limit, bool) or not 1 <= limit <= 50:
        raise Refused("limit is 1 to 50")
    tasks = proxmox("/cluster/tasks") or []
    failed = [pick(t, ["node", "type", "id", "user", "starttime", "endtime", "status"]) for t in tasks
              if t.get("status") and t.get("status") != "OK"]
    failed.sort(key=lambda t: t.get("endtime") or t.get("starttime") or 0, reverse=True)
    return {"failed_tasks": failed[:limit], "looked_at": len(tasks)}


# -- Beszel -------------------------------------------------------------------

_beszel = {}


def beszel(collection, params):
    if collection not in BESZEL_COLLECTIONS:
        raise Refused(f"the Beszel collection {collection!r} isn't one this tool reads")
    base = env("BESZEL_URL").rstrip("/")
    if not base or not env("BESZEL_USER") or not env("BESZEL_PASSWORD"):
        raise Refused("Beszel isn't set up (BESZEL_URL, BESZEL_USER, BESZEL_PASSWORD)")
    check_url(base, "BESZEL_URL")
    deadline = time.monotonic() + DEADLINE
    url = f"{base}/api/collections/{collection}/records?{urllib.parse.urlencode(params)}"
    for attempt in range(2):
        if not _beszel.get("token") or time.monotonic() > _beszel.get("until", 0):
            login = request("POST", f"{base}/api/collections/users/auth-with-password", {},
                            {"identity": env("BESZEL_USER"), "password": env("BESZEL_PASSWORD")}, deadline=deadline)
            if not isinstance(login, dict) or not login.get("token"):
                raise Refused("Beszel's login answered without a token")
            _beszel.update(token=login["token"], until=time.monotonic() + 1800)
        try:
            answer = request("GET", url, {"Authorization": _beszel["token"]}, deadline=deadline)
            return answer.get("items", []) if isinstance(answer, dict) else []
        except Refused as err:
            if attempt == 0 and ("HTTP 401" in str(err) or "HTTP 403" in str(err)):
                _beszel.clear()
                continue
            raise
    raise Refused("Beszel refused the login")


def beszel_systems():
    systems = beszel("systems", {"perPage": 200, "sort": "name", "fields": "id,name,status,host,info,updated"})
    return {"systems": [pick(s, ["name", "status", "host", "info", "updated"]) for s in systems],
            "note": "info uses Beszel's short field names"}


def beszel_system(name):
    if not isinstance(name, str) or not SYSTEM.fullmatch(name):
        raise Refused("name is a Beszel system's name: letters, digits, spaces, '.', '_' or '-'")
    found = beszel("systems", {"filter": f"(name='{name}')", "perPage": 1, "fields": "id,name,status,host,info,updated"})
    if not found:
        raise Refused(f"no Beszel system called {name!r}")
    system = found[0]
    stats = beszel("system_stats", {"filter": f"(system='{system['id']}'&&type='1m')", "sort": "-created",
                                    "perPage": 1, "fields": "created,stats"})
    services = beszel("systemd_services", {"filter": f"(system='{system['id']}')", "perPage": 200})
    return fit({**pick(system, ["name", "status", "host", "info", "updated"]),
                "latest_stats": stats[0] if stats else None,
                "systemd_services": [{k: v for k, v in s.items() if k not in ("id", "system", "collectionId",
                                                                            "collectionName")} for s in services]})


# -- Kuma ---------------------------------------------------------------------

def kuma_monitors():
    base, slug = env("KUMA_URL").rstrip("/"), env("KUMA_SLUG")
    if not base or not re.fullmatch(r"[a-z0-9-]{1,64}", slug or ""):
        raise Refused("Kuma isn't set up (KUMA_URL, KUMA_SLUG)")
    check_url(base, "KUMA_URL")
    deadline = time.monotonic() + DEADLINE
    page = request("GET", f"{base}/api/status-page/{slug}", {}, deadline=deadline) or {}
    beats = request("GET", f"{base}/api/status-page/heartbeat/{slug}", {}, deadline=deadline) or {}
    lists, uptimes = beats.get("heartbeatList") or {}, beats.get("uptimeList") or {}
    monitors = []
    for group in page.get("publicGroupList") or []:
        for monitor in group.get("monitorList") or []:
            history = lists.get(str(monitor.get("id"))) or []
            last = history[-1] if history else {}
            state = last.get("status")
            since = None
            for beat in reversed(history):
                if beat.get("status") != state:
                    break
                since = beat.get("time")
            monitors.append({"group": group.get("name"), "name": monitor.get("name"), "type": monitor.get("type"),
                             "state": KUMA_STATES.get(state, "unknown"), "since": since, "ping_ms": last.get("ping"),
                             "uptime_24h": uptimes.get(f"{monitor.get('id')}_24")})
    down = [m["name"] for m in monitors if m["state"] != "up"]
    return fit({"monitors": monitors, "not_up": down})


# -- Alerta -------------------------------------------------------------------

ALERT_FIELDS = ["id", "resource", "event", "environment", "severity", "status", "service", "group", "value",
                "text", "createTime", "lastReceiveTime", "duplicateCount"]


def alerta(path, params=None):
    base, key = env("ALERTA_URL").rstrip("/"), env("ALERTA_KEY")
    if not base or not key:
        raise Refused("Alerta isn't set up (ALERTA_URL, ALERTA_KEY)")
    check_url(base, "ALERTA_URL")
    query = f"?{urllib.parse.urlencode(params, doseq=True)}" if params else ""
    # Alerta's API is at the root; /api is only the web UI's proxy for it.
    return request("GET", f"{base}{path}{query}", {"Authorization": f"Key {key}"}) or {}


def alerta_alerts(status="open", severity=None, limit=50):
    if status not in ALERT_STATUSES:
        raise Refused(f"status is one of {', '.join(sorted(ALERT_STATUSES))}")
    if severity is not None and severity not in SEVERITIES:
        raise Refused(f"severity is one of {', '.join(sorted(SEVERITIES))}")
    if not isinstance(limit, int) or isinstance(limit, bool) or not 1 <= limit <= 100:
        raise Refused("limit is 1 to 100")
    params = {"status": status, "page-size": limit, "sort-by": "lastReceiveTime"}
    if severity:
        params["severity"] = severity
    answer = alerta("/alerts", params)
    return fit({"total": answer.get("total"), "alerts": [pick(a, ALERT_FIELDS) for a in answer.get("alerts") or []]})


def alerta_alert(alert_id):
    if not isinstance(alert_id, str) or not ALERT_ID.fullmatch(alert_id):
        raise Refused("id is an Alerta alert id")
    alert = (alerta(f"/alert/{alert_id}") or {}).get("alert") or {}
    history = [pick(h, ["event", "severity", "status", "value", "text", "type", "updateTime"])
               for h in alert.get("history") or []]
    return fit({**pick(alert, ALERT_FIELDS), "history": history})


# -- Tools ----------------------------------------------------------------------

def log_call(call_id, tool, status):
    path = env("LAB_CALL_LOG")
    if not path:
        return
    when = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        with os.fdopen(fd, "a") as f:
            f.write(f"{when} call={call_id} tool={tool} status={status}\n")
    except OSError as err:
        print(f"lab: couldn't write the call log: {err}", file=sys.stderr)


def run(tool, fn, *args):
    """fn's answer with this call's id, logged either way."""
    call_id = secrets.token_hex(6)
    try:
        result = fn(*args)
    except Refused as err:
        log_call(call_id, tool, "error")
        raise Refused(f"{err} (call {call_id})") from None
    log_call(call_id, tool, "ok")
    return {"call_id": call_id, **result}


PROXMOX_NOTE = "Read-only; it never shows VM configs or task logs."
TOOLS = {
    "proxmox": [
        ("proxmox_cluster", proxmox_cluster,
         "The Proxmox cluster: whether it has quorum, which nodes are online, and the HA resources' states. " + PROXMOX_NOTE),
        ("proxmox_resources", proxmox_resources,
         "Every node, VM and container (type 'vm'), or storage on the cluster, with status and CPU, memory "
         "and disk use (bytes; cpu is a fraction of maxcpu). type: node, vm or storage. " + PROXMOX_NOTE),
        ("proxmox_node", proxmox_node,
         "One Proxmox node's load, CPU, memory, swap, root disk, uptime and versions. node: its name. " + PROXMOX_NOTE),
        ("proxmox_guest", proxmox_guest,
         "One VM's or container's current status and resource use. node: where it runs; vmid: its id. " + PROXMOX_NOTE),
        ("proxmox_failed_tasks", proxmox_failed_tasks,
         "The cluster's most recent failed tasks (backups, migrations, starts), newest first, without their logs. "
         "limit: 1 to 50."),
    ],
    "beszel": [
        ("beszel_systems", beszel_systems,
         "Every system Beszel watches, with its status (up, down, paused) and summary info."),
        ("beszel_system", beszel_system,
         "One Beszel system's latest one-minute stats and its systemd services. name: the system's name."),
    ],
    "kuma": [
        ("kuma_monitors", kuma_monitors,
         "Every Uptime Kuma monitor on the agents' status page: up, down, pending or in maintenance, since when, "
         "its last response time and its 24-hour uptime."),
    ],
    "alerta": [
        ("alerta_alerts", alerta_alerts,
         "Alerta's alerts, newest first. status: open (default), ack, closed, shelved or expired; severity: "
         "optional, e.g. critical or warning; limit: 1 to 100. Read-only."),
        ("alerta_alert", alerta_alert, "One Alerta alert with its history. alert_id: its id. Read-only."),
    ],
}
SOURCES = {"proxmox": "PROXMOX_URLS", "beszel": "BESZEL_URL", "kuma": "KUMA_URL", "alerta": "ALERTA_URL"}


def enabled_sources():
    return [s for s, var in SOURCES.items() if env(var)]


def main():
    from mcp.server.mcpserver import MCPServer
    from mcp.server.mcpserver.exceptions import ToolError
    from mcp.types import ToolAnnotations

    server = MCPServer("lab")

    def register(name, fn, description):
        annotations = ToolAnnotations(title=name.replace("_", " "), readOnlyHint=True, idempotentHint=True,
                                      destructiveHint=False, openWorldHint=False)

        def answer(*args):
            try:
                return json.dumps(run(name, fn, *args), ensure_ascii=False)
            except Refused as err:
                # Only a ToolError's message reaches the agent.
                raise ToolError(str(err)) from None

        # MCPServer reads each tool's arguments from its signature, so each gets
        # its own small function.
        if fn in (proxmox_cluster, beszel_systems, kuma_monitors):
            def tool() -> str:
                return answer()
        elif fn is proxmox_resources:
            def tool(type: str) -> str:  # noqa: A002 - the tool's argument name
                return answer(type)
        elif fn is proxmox_node:
            def tool(node: str) -> str:
                return answer(node)
        elif fn is proxmox_guest:
            def tool(node: str, vmid: int) -> str:
                return answer(node, vmid)
        elif fn is proxmox_failed_tasks:
            def tool(limit: int = 20) -> str:
                return answer(limit)
        elif fn is beszel_system:
            def tool(name: str) -> str:
                return answer(name)
        elif fn is alerta_alerts:
            def tool(status: str = "open", severity: str | None = None, limit: int = 50) -> str:
                return answer(status, severity, limit)
        else:
            def tool(alert_id: str) -> str:
                return answer(alert_id)
        server.tool(name=name, description=description, structured_output=False, annotations=annotations)(tool)

    for source in enabled_sources():
        for name, fn, description in TOOLS[source]:
            register(name, fn, description)
    server.run()


if __name__ == "__main__":
    main()
