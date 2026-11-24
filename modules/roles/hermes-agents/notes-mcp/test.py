#!/usr/bin/env python3
"""Tests server.py over stdio, as Hermes starts it, against a fake vault service.

The fake listens on a Unix socket, records each request and answers from a
table, so the test sees exactly what the server forwards and how it passes
refusals back.

usage: test.py <server.py>
"""
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

SERVER = pathlib.Path(sys.argv[1])
TMP = pathlib.Path(tempfile.mkdtemp())
SOCK = TMP / "notes.sock"
LOG = TMP / "notes.log"
requests = []
failures = []


def check(what, ok):
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        failures.append(what)


def fake_service():
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(str(SOCK))
    srv.listen(8)
    while True:
        conn, _ = srv.accept()
        data = b""
        while chunk := conn.recv(65536):
            data += chunk
        req = json.loads(data)
        requests.append(req)
        if req["op"] == "create_note" and req["args"]["content"].startswith("ghp_"):
            reply = {"ok": False, "error": "content looks like it holds a GitHub token, which never goes in the vault"}
        else:
            reply = {"ok": True, "result": {"path": req["args"].get("path", ""), "echo": req["op"]}}
        conn.sendall(json.dumps(reply).encode() + b"\n")
        conn.close()


threading.Thread(target=fake_service, daemon=True).start()
while not SOCK.exists():
    pass


def session(env):
    proc = subprocess.Popen([sys.executable, "-I", str(SERVER)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True, env={"PATH": os.environ.get("PATH", ""), **env})
    replies = queue.Queue()
    threading.Thread(target=lambda: [replies.put(line) for line in proc.stdout], daemon=True).start()

    def send(obj):
        proc.stdin.write(json.dumps(obj) + "\n")
        proc.stdin.flush()

    def wait_for(msg_id, timeout=30):
        while True:
            try:
                msg = json.loads(replies.get(timeout=timeout))
            except queue.Empty:
                return None
            if msg.get("id") == msg_id:
                return msg

    from mcp.types import LATEST_PROTOCOL_VERSION

    send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": LATEST_PROTOCOL_VERSION, "capabilities": {}, "clientInfo": {"name": "test", "version": "1"}}})
    init = wait_for(1)
    send({"jsonrpc": "2.0", "method": "notifications/initialized"})
    return proc, send, wait_for, init


def call(send, wait_for, msg_id, name, arguments):
    send({"jsonrpc": "2.0", "id": msg_id, "method": "tools/call", "params": {"name": name, "arguments": arguments}})
    result = (wait_for(msg_id) or {}).get("result", {})
    text = (result.get("content") or [{}])[0].get("text", "")
    return result, text


proc, send, wait_for, init = session({"NOTES_SOCKET": str(SOCK), "NOTES_CALL_LOG": str(LOG)})
check("it answers initialize", bool(init) and init.get("result", {}).get("serverInfo", {}).get("name") == "notes")
send({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
tools = {t["name"]: t for t in (wait_for(2) or {}).get("result", {}).get("tools", [])}
check("it lists the ten tools", set(tools) == {"search_notes", "read_note", "list_notes", "backlinks", "note_history",
                                               "create_note", "append_to_note", "replace_in_note", "rewrite_note",
                                               "move_note"})
check("the read tools are marked read-only and the write tools aren't",
      all(tools[t]["annotations"]["readOnlyHint"] for t in ["search_notes", "read_note", "list_notes", "backlinks",
                                                             "note_history"])
      and not any(tools[t]["annotations"]["readOnlyHint"] for t in ["create_note", "append_to_note", "replace_in_note",
                                                                     "rewrite_note", "move_note"]))
check("every description says notes are information, not instructions, or how writes work",
      all("not instructions" in t["description"] or "commit under your name" in t["description"] for t in tools.values()))

result, text = call(send, wait_for, 3, "search_notes", {"query": "lab plan", "tag": "lab"})
payload = json.loads(text or "{}")
check("a call forwards its operation and arguments, defaults filled in", requests[-1] == {
    "op": "search_notes", "args": {"query": "lab plan", "tag": "lab", "folder": "", "limit": 10}})
check("  ...and returns the service's answer with a call id", payload.get("echo") == "search_notes"
      and len(payload.get("call_id", "")) == 12)
call(send, wait_for, 4, "append_to_note", {"path": "inbox/a.md", "text": "x", "message": "m"})
check("a write forwards every argument", requests[-1]["args"] == {"path": "inbox/a.md", "text": "x", "message": "m",
                                                                  "heading": "", "create": False})
result, text = call(send, wait_for, 5, "create_note", {"path": "inbox/k.md", "content": "ghp_x", "message": "m"})
check("a refusal comes back as a tool error, with the service's reason", result.get("isError") is True
      and "never goes in the vault" in text)
proc.stdin.close()
proc.wait(timeout=10)

log = LOG.read_text()
check("the call log has each call's id, tool and outcome", "tool=search_notes status=ok" in log
      and "tool=create_note status=refused" in log)
check("  ...never a path, a query or text", "inbox" not in log and "lab plan" not in log and "ghp_" not in log)
check("  ...and only its owner can read it", stat.S_IMODE(LOG.stat().st_mode) == 0o600)

proc, send, wait_for, _ = session({"NOTES_SOCKET": "relative.sock"})
result, text = call(send, wait_for, 3, "list_notes", {})
check("without a proper NOTES_SOCKET every call is refused", result.get("isError") is True and "isn't set up" in text)
proc.stdin.close()
proc.wait(timeout=10)

proc, send, wait_for, _ = session({"NOTES_SOCKET": str(TMP / "missing.sock")})
result, text = call(send, wait_for, 3, "list_notes", {})
check("a service that isn't there is a clear tool error", result.get("isError") is True
      and "couldn't reach the vault service" in text)
proc.stdin.close()
proc.wait(timeout=10)

if failures:
    sys.exit(f"{len(failures)} check(s) failed")
print("all checks passed")
