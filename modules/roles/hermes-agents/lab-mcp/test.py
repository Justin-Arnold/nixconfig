#!/usr/bin/env python3
"""Tests the lab MCP server against fake Proxmox, Beszel, Kuma and Alerta APIs.

One fake answers for all four, records every request, and refuses a wrong
token or key by echoing it back. The tests check what each tool asks for and
returns (only the fields it picks), that only GETs are sent apart from
Beszel's login, that VM configs and Beszel's fingerprints are never asked
for, Proxmox failing over to a second node, every argument check, that no
secret shows up in an error or the call log, and the server over stdio as
Hermes starts it.

usage: test.py <server.py>
"""
import importlib.util
import json
import os
import pathlib
import queue
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SERVER = pathlib.Path(sys.argv[1])
TOKEN = "agents@pve!observe=" + "5f" * 16
PASSWORD = "beszel-" + "9c" * 12
SESSION = "beszel-session-" + "7e" * 10
KEY = "alerta-" + "3d" * 16
TMP = pathlib.Path(tempfile.mkdtemp())
failures = []
requests = []


def check(what, ok):
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        failures.append(what)


ALERT = {"id": "a1b2c3d4-0000-4000-8000-000000000001", "resource": "paperclip/LAB-1", "event": "MarkedChange",
         "environment": "Production", "severity": "warning", "status": "open", "text": "LAB-1 is labelled change",
         "attributes": {"ip": "198.51.100.7"}, "rawData": "raw", "createTime": "t0", "lastReceiveTime": "t1"}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def route(self, method):
        parts = urllib.parse.urlsplit(self.path)
        path, query = parts.path, dict(urllib.parse.parse_qsl(parts.query))
        auth = self.headers.get("Authorization")
        body = None
        if method == "POST":
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        requests.append({"method": method, "path": path, "query": query})

        if path.startswith("/api2/json/"):
            if auth != f"PVEAPIToken={TOKEN}":
                return self.reply(401, {"message": f"invalid token {auth}"})
            return self.proxmox(path.removeprefix("/api2/json"), query)
        if path == "/api/collections/users/auth-with-password":
            if body != {"identity": "agents@example.com", "password": PASSWORD}:
                return self.reply(400, {"message": f"Failed to authenticate {body}"})
            return self.reply(200, {"token": SESSION, "record": {"id": "u1"}})
        if path.startswith("/api/collections/"):
            if auth != SESSION:
                return self.reply(401, {"message": "unauthorized"})
            return self.beszel(path.split("/")[3], query)
        if path == "/api/status-page/agents":
            return self.reply(200, {"config": {"title": "Agents"}, "publicGroupList": [{"name": "Services", "monitorList": [
                {"id": 1, "name": "SVC / paperclip", "type": "http"}, {"id": 2, "name": "JOB / agent-watch", "type": "push"}]}]})
        if path == "/api/status-page/heartbeat/agents":
            return self.reply(200, {"heartbeatList": {
                "1": [{"status": 1, "time": "t1", "ping": 20, "msg": ""}, {"status": 1, "time": "t2", "ping": 21, "msg": ""}],
                "2": [{"status": 1, "time": "t1"}, {"status": 0, "time": "t2"}, {"status": 0, "time": "t3"}]},
                "uptimeList": {"1_24": 1.0, "2_24": 0.5}})
        if path == "/alerts" or path.startswith("/alert/"):
            if auth != f"Key {KEY}":
                return self.reply(401, {"message": f"invalid key {auth}"})
            if path == "/alerts":
                return self.reply(200, {"status": "ok", "total": 1, "alerts": [ALERT]})
            return self.reply(200, {"status": "ok", "alert": {**ALERT, "history": [
                {"event": "MarkedChange", "severity": "warning", "status": "open", "text": "raised", "type": "new",
                 "updateTime": "t0", "user": "justin@example.com"}]}})
        self.reply(404, {"message": "not found"})

    def proxmox(self, path, query):
        if "/config" in path:
            return self.reply(200, {"data": {"cipassword": "should never be asked for"}})
        if path == "/cluster/status":
            return self.reply(200, {"data": [
                {"type": "cluster", "name": "lab", "quorate": 1, "nodes": 2, "version": 9, "id": "cluster"},
                {"type": "node", "name": "proxmox4", "online": 1, "ip": "10.0.0.14", "local": 1, "nodeid": 1},
                {"type": "node", "name": "proxmox8", "online": 0, "ip": "10.0.0.18", "local": 0, "nodeid": 2}]})
        if path == "/cluster/ha/status/current":
            return self.reply(200, {"data": [{"id": "vm:105", "type": "service", "status": "started", "node": "proxmox5",
                                              "crm_state": "started", "sid": "vm:105"}]})
        if path == "/cluster/resources":
            kind = query.get("type")
            items = {"vm": [{"vmid": 105, "name": "agents", "node": "proxmox5", "type": "qemu", "status": "running",
                             "cpu": 0.1, "maxcpu": 4, "mem": 1, "maxmem": 2, "diskwrite": 9, "secret": "nope"}],
                     "node": [{"node": "proxmox4", "status": "online", "cpu": 0.2, "maxcpu": 16, "level": ""}],
                     "storage": [{"storage": "local-lvm", "node": "proxmox4", "status": "available", "disk": 5, "maxdisk": 9}]}
            return self.reply(200, {"data": items.get(kind, [])})
        if path == "/nodes/proxmox4/status":
            return self.reply(200, {"data": {"uptime": 100, "loadavg": ["0.1", "0.2", "0.3"], "cpu": 0.05,
                                             "cpuinfo": {"model": "EPYC", "cpus": 16, "flags": "long"},
                                             "memory": {"used": 1, "total": 2}, "rootfs": {"used": 3, "total": 4},
                                             "swap": {"used": 0, "total": 1}, "pveversion": "pve-manager/9.0",
                                             "boot-info": {"mode": "efi"}}})
        if path == "/nodes/proxmox4/qemu/105/status/current":
            return self.reply(200, {"data": {"vmid": 105, "name": "agents", "status": "running", "cpu": 0.1,
                                             "mem": 1, "maxmem": 2, "nics": {"net0": {}}, "proxmox-support": {}}})
        if path == "/nodes/proxmox4/qemu/200/status/current":
            return self.reply(500, {"data": None, "message": "Configuration file 'nodes/proxmox4/qemu-server/200.conf' does not exist"})
        if path == "/nodes/proxmox4/lxc/200/status/current":
            return self.reply(200, {"data": {"vmid": 200, "name": "ct", "status": "stopped"}})
        if path == "/cluster/tasks":
            return self.reply(200, {"data": [
                {"node": "proxmox4", "type": "vzdump", "id": "105", "user": "root@pam", "starttime": 10, "endtime": 20,
                 "status": "job errors", "upid": "UPID:x"},
                {"node": "proxmox4", "type": "qmstart", "id": "106", "user": "root@pam", "starttime": 30, "endtime": 31,
                 "status": "OK"},
                {"node": "proxmox8", "type": "qmigrate", "id": "107", "user": "root@pam", "starttime": 40}]})
        self.reply(404, {"data": None})

    def beszel(self, collection, query):
        items = {
            "systems": [{"id": "s1", "name": "agents", "status": "up", "host": "10.0.0.152", "info": {"cpu": 5},
                         "updated": "t", "collectionId": "c"}],
            "system_stats": [{"created": "t", "stats": {"cpu": 5.5}}],
            "systemd_services": [{"id": "x", "system": "s1", "name": "nginx.service", "state": 1, "collectionId": "c"}],
            "fingerprints": [{"token": "agent-token-should-never-be-read"}],
        }.get(collection, [])
        if collection == "systems" and "filter" in query and "agents" not in query["filter"]:
            items = []
        self.reply(200, {"items": items, "totalItems": len(items)})

    def reply(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=httpd.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{httpd.server_address[1]}"
closed = socket.socket()
closed.bind(("127.0.0.1", 0))
DEAD = f"http://127.0.0.1:{closed.getsockname()[1]}"
closed.close()
LOG = TMP / "lab.log"

ENV = {"PROXMOX_URLS": f"{DEAD},{BASE}", "PROXMOX_TOKEN": TOKEN,
       "BESZEL_URL": BASE, "BESZEL_USER": "agents@example.com", "BESZEL_PASSWORD": PASSWORD,
       "KUMA_URL": BASE, "KUMA_SLUG": "agents", "ALERTA_URL": BASE, "ALERTA_KEY": KEY, "LAB_CALL_LOG": str(LOG)}
os.environ.update(ENV)
spec = importlib.util.spec_from_file_location("lab_server", SERVER)
lab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lab)


def error(fn, *args):
    """The Refused message from lab.run, or None if it went through."""
    try:
        lab.run(fn.__name__, fn, *args)
    except lab.Refused as err:
        return str(err)
    return None


# Proxmox
cluster = lab.run("proxmox_cluster", lab.proxmox_cluster)
check("proxmox_cluster fails over to the second node and reports quorum, nodes and HA",
      cluster["cluster"].get("quorate") == 1 and [n["name"] for n in cluster["nodes"]] == ["proxmox4", "proxmox8"]
      and cluster["ha"][0]["id"] == "vm:105" and len(cluster["call_id"]) == 12)
check("it keeps only the fields it picks", "nodeid" not in cluster["nodes"][0] and "sid" not in cluster["ha"][0])
vms = lab.proxmox_resources("vm")
check("proxmox_resources lists VMs without fields it doesn't name",
      vms["items"][0]["name"] == "agents" and "secret" not in vms["items"][0] and "diskwrite" not in vms["items"][0])
check("proxmox_resources refuses an unknown type", "type must be" in (error(lab.proxmox_resources, "pool") or ""))
node = lab.proxmox_node("proxmox4")
check("proxmox_node reports load and memory, not boot info or CPU flags",
      node["memory"] == {"used": 1, "total": 2} and "boot-info" not in node and "flags" not in node["cpuinfo"])
for bad in ("proxmox4/../../access/users", "Proxmox4", "", "a" * 70):
    check(f"proxmox_node refuses the node name {bad[:20]!r}", "node is a Proxmox node name" in (error(lab.proxmox_node, bad) or ""))
guest = lab.proxmox_guest("proxmox4", 105)
check("proxmox_guest reads a VM's status without its NICs", guest["kind"] == "qemu" and "nics" not in guest)
check("proxmox_guest finds a container when the id isn't a VM", lab.proxmox_guest("proxmox4", 200)["kind"] == "lxc")
for bad in (99, "105", True, 10 ** 10):
    check(f"proxmox_guest refuses the vmid {bad!r}", "vmid is a number" in (error(lab.proxmox_guest, "proxmox4", bad) or ""))
tasks = lab.proxmox_failed_tasks(5)
check("proxmox_failed_tasks keeps only failures, without the UPID",
      [t["id"] for t in tasks["failed_tasks"]] == ["105"] and "upid" not in tasks["failed_tasks"][0] and tasks["looked_at"] == 3)
check("proxmox_failed_tasks refuses a limit over 50", "limit is 1 to 50" in (error(lab.proxmox_failed_tasks, 500) or ""))
os.environ["PROXMOX_TOKEN"] = "agents@pve!observe=" + "00" * 16
wrong = error(lab.proxmox_cluster) or ""
check("a refused Proxmox token is an error that doesn't fail over or show the token",
      "HTTP 401" in wrong and "no Proxmox node answered" not in wrong and "00" * 16 not in wrong)
os.environ["PROXMOX_TOKEN"] = TOKEN
os.environ["PROXMOX_URLS"] = DEAD
check("with no node up it says so", "no Proxmox node answered" in (error(lab.proxmox_cluster) or ""))
os.environ["PROXMOX_URLS"] = f"{DEAD},{BASE}"

# Beszel
systems = lab.beszel_systems()
check("beszel_systems lists systems with their status", systems["systems"][0] == {
    "name": "agents", "status": "up", "host": "10.0.0.152", "info": {"cpu": 5}, "updated": "t"})
one = lab.beszel_system("agents")
check("beszel_system gives the latest stats and services without Beszel's ids",
      one["latest_stats"]["stats"]["cpu"] == 5.5 and one["systemd_services"] == [{"name": "nginx.service", "state": 1}])
check("beszel_system says when there's no such system", "no Beszel system called" in (error(lab.beszel_system, "ghost") or ""))
for bad in ("x' || name!='", "a/b", ""):
    check(f"beszel_system refuses the name {bad!r}", "name is a Beszel system's name" in (error(lab.beszel_system, bad) or ""))
check("the fingerprints collection can't be read at all",
      "isn't one this tool reads" in (error(lambda: lab.beszel("fingerprints", {})) or ""))
logins = [r for r in requests if r["path"].endswith("auth-with-password")]
check("Beszel signs in once and reuses the session", len(logins) == 1)
lab._beszel["token"] = "expired"
lab.beszel_systems()
check("an expired session signs in again", len([r for r in requests if r["path"].endswith("auth-with-password")]) == 2)

# Kuma
kuma = lab.kuma_monitors()
by_name = {m["name"]: m for m in kuma["monitors"]}
check("kuma_monitors gives each monitor's state, since when, and uptime",
      by_name["SVC / paperclip"]["state"] == "up" and by_name["JOB / agent-watch"]["state"] == "down"
      and by_name["JOB / agent-watch"]["since"] == "t2" and by_name["JOB / agent-watch"]["uptime_24h"] == 0.5
      and kuma["not_up"] == ["JOB / agent-watch"])

# Alerta
alerts = lab.alerta_alerts()
check("alerta_alerts lists open alerts without their attributes or raw data",
      alerts["total"] == 1 and alerts["alerts"][0]["event"] == "MarkedChange"
      and "attributes" not in alerts["alerts"][0] and "rawData" not in alerts["alerts"][0])
sent = [r for r in requests if r["path"] == "/alerts"][-1]["query"]
check("it asks Alerta for open alerts, newest first", sent.get("status") == "open" and sent.get("sort-by") == "lastReceiveTime")
check("alerta_alerts refuses an unknown status", "status is one of" in (error(lab.alerta_alerts, "deleted") or ""))
check("alerta_alerts refuses an unknown severity", "severity is one of" in (error(lab.alerta_alerts, "open", "doom") or ""))
alert = lab.alerta_alert(ALERT["id"])
check("alerta_alert includes the history, without who changed it",
      alert["history"][0]["status"] == "open" and "user" not in alert["history"][0])
check("alerta_alert refuses an id that isn't one", "id is an Alerta alert id" in (error(lab.alerta_alert, "../keys") or ""))
os.environ["ALERTA_KEY"] = "alerta-" + "00" * 16
wrong = error(lab.alerta_alerts) or ""
check("a refused Alerta key is an error that doesn't show the key", "HTTP 401" in wrong and "00" * 16 not in wrong)
os.environ["ALERTA_KEY"] = KEY

# Endpoints
for url, ok in (("http://10.0.0.5:8006", False), ("http://example.com", False), ("ftp://10.118.0.1", False),
                ("http://10.118.0.1:5000", True), ("https://10.0.0.14:8006", True), ("http://127.0.0.1:1", True)):
    try:
        lab.check_url(url, "X")
        allowed = True
    except lab.Refused:
        allowed = False
    check(f"{url} is {'allowed' if ok else 'refused'}", allowed == ok)

# What was sent
check("only Beszel's login is a POST; everything else is a GET",
      {r["method"] for r in requests if not r["path"].endswith("auth-with-password")} == {"GET"}
      and all(r["path"].endswith("auth-with-password") for r in requests if r["method"] == "POST"))
check("no VM config and no Beszel fingerprints were ever asked for",
      not any("/config" in r["path"] or "fingerprints" in r["path"] for r in requests))

# The call log
log = LOG.read_text()
check("every call is in the call log with its tool and outcome",
      f"call={cluster['call_id']} tool=proxmox_cluster status=ok" in log and "status=error" in log)
check("the call log holds no answers and no secrets",
      not any(s in log for s in ("SVC / paperclip", "MarkedChange", "proxmox4", TOKEN, PASSWORD, KEY, SESSION)))
check("the call log is readable by its owner only", stat.S_IMODE(LOG.stat().st_mode) == 0o600)

# Over stdio, as Hermes starts it.
from mcp.types import LATEST_PROTOCOL_VERSION  # noqa: E402


def session(env, calls):
    proc = subprocess.Popen([sys.executable, "-I", str(SERVER)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True,
                            env={"PATH": os.environ.get("PATH", ""), "HOME": str(TMP), **env})
    replies = queue.Queue()
    threading.Thread(target=lambda: [replies.put(line) for line in proc.stdout], daemon=True).start()

    def send(obj):
        proc.stdin.write(json.dumps(obj) + "\n")
        proc.stdin.flush()

    def wait_for(msg_id):
        while True:
            try:
                msg = json.loads(replies.get(timeout=20))
            except queue.Empty:
                return None
            if msg.get("id") == msg_id:
                return msg

    send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": LATEST_PROTOCOL_VERSION, "capabilities": {}, "clientInfo": {"name": "test", "version": "1"}}})
    out = [wait_for(1)]
    send({"jsonrpc": "2.0", "method": "notifications/initialized"})
    send({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
    out.append(wait_for(2))
    for i, (name, arguments) in enumerate(calls, start=3):
        send({"jsonrpc": "2.0", "id": i, "method": "tools/call", "params": {"name": name, "arguments": arguments}})
        out.append(wait_for(i))
    proc.stdin.close()
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()
    return out, proc.stderr.read()


def tool_text(reply):
    result = (reply or {}).get("result", {})
    return result, (result.get("content") or [{}])[0].get("text", "")


out, stderr = session({**ENV, "LAB_CALL_LOG": str(TMP / "stdio.log")},
                      [("kuma_monitors", {}), ("proxmox_guest", {"node": "proxmox4", "vmid": 105}),
                       ("proxmox_node", {"node": "../access"})])
check("it answers initialize as lab", (out[0] or {}).get("result", {}).get("serverInfo", {}).get("name") == "lab")
tools = (out[1] or {}).get("result", {}).get("tools", [])
check("with all four sources set it lists ten tools, all read-only",
      len(tools) == 10 and all(t.get("annotations", {}).get("readOnlyHint") is True for t in tools))
check("proxmox_guest's schema asks for node and vmid",
      any(t["name"] == "proxmox_guest" and set(t["inputSchema"].get("required", [])) == {"node", "vmid"} for t in tools))
result, text = tool_text(out[2])
check("kuma_monitors over stdio returns the monitors with a call id",
      not result.get("isError") and len(json.loads(text or "{}").get("call_id", "")) == 12)
result, text = tool_text(out[3])
check("proxmox_guest over stdio reads the VM", not result.get("isError") and json.loads(text or "{}").get("name") == "agents")
result, _ = tool_text(out[4])
check("a bad argument over stdio is a tool error saying why",
      result.get("isError") is True and "node is a Proxmox node name" in json.dumps(result))
check("no secret appears in anything the server printed",
      not any(s in stderr + json.dumps(out) for s in (TOKEN, PASSWORD, KEY, SESSION)))

out, _ = session({"KUMA_URL": BASE, "KUMA_SLUG": "agents"}, [])
check("with only Kuma set it lists only kuma_monitors",
      [t["name"] for t in (out[1] or {}).get("result", {}).get("tools", [])] == ["kuma_monitors"])

httpd.shutdown()
if failures:
    sys.exit(f"{len(failures)} check(s) failed")
print("all checks passed")
