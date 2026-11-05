#!/usr/bin/env python3
"""Tests the Jev MCP server against a fake TypeSafe System One API.

The fake answers like Jev does (noul, choice and score answers, usage) and can
rate-limit, refuse the key or echo it back. The tests check what's sent (the
path, the bearer key, the pinned model, the questions as given), every check
that stops a request before it's sent, the 429 retry, that the key and the
text never show up in errors or the call log, and finally the server over
stdio as Hermes starts it: initialize, tools/list, tools/call.

usage: test.py <server.py>
"""
import importlib.util
import json
import os
import pathlib
import queue
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SERVER = pathlib.Path(sys.argv[1])
KEY = "jev-test-" + "4b" * 16
TMP = pathlib.Path(tempfile.mkdtemp())
failures = []


def check(what, ok):
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        failures.append(what)


class Fake:
    def __init__(self):
        self.reset()

    def reset(self, mode="ok", throttle=0):
        self.mode, self.throttle, self.requests = mode, throttle, []


fake = Fake()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        fake.requests.append({"path": self.path, "auth": self.headers.get("Authorization"), "body": body})
        if fake.throttle:
            fake.throttle -= 1
            return self.reply(429, {"error": "rate limited"}, {"Retry-After": "0.2"})
        if fake.mode == "billing":
            return self.reply(402, {"error": "insufficient credits: top up your account"})
        if fake.mode == "unauthorized":
            return self.reply(401, {"detail": f"invalid key {self.headers.get('Authorization')}"})
        answers = {}
        for name, q in body["questions"].items():
            if q["type"] == "noul":
                answers[name] = {"type": "noul", "noul": 0.91}
            elif q["type"] == "choice":
                options = list(q["criteria"])
                probs = {o: (0.8 if i == 0 else 0.2 / max(1, len(options) - 1)) for i, o in enumerate(options)}
                answers[name] = {"type": "choice", "choice": options[0], "confidence": 0.7, "probabilities": probs}
            else:
                levels = {str(i): text for i, text in enumerate(q["criteria"])}
                answers[name] = {"type": "score", "score": 1.4, "confidence": 0.6, "legend": levels,
                                 "probabilities": {k: 1 / len(levels) for k in levels}}
        self.reply(200, {"model": body["model"], "answers": answers,
                         "usage": {"input_tokens": 120, "output_tokens": 4}})

    def reply(self, code, obj, headers=None):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)


httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=httpd.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{httpd.server_address[1]}/v1"
LOG = TMP / "jev.log"

os.environ.update({"JEV_API_KEY": KEY, "JEV_BASE_URL": BASE, "JEV_CALL_LOG": str(LOG), "JEV_DEADLINE": "10"})
spec = importlib.util.spec_from_file_location("jev_server", SERVER)
jev = importlib.util.module_from_spec(spec)
spec.loader.exec_module(jev)

STATE = "The backup disk on nas-disk-2 is 97% full and SMART reports reallocated sectors. canary-text-7f3a"
QUESTIONS = {
    "human": {"type": "noul", "instructions": "Does this need a human today?",
              "criteria": {"true": "Someone has to act today", "false": "It can wait"}},
    "team": {"type": "choice", "instructions": "Who owns this?", "criteria": {"storage": "Disks and backups", "network": None}},
    "urgency": {"type": "score", "instructions": "How urgent is it?", "criteria": ["Routine", "This week", "Today", "Now"]},
}


def refused(state, questions):
    """The Refused message, or None if the call went through."""
    try:
        jev.decide(state, questions)
    except jev.Refused as err:
        return str(err)
    return None


# A call that goes through.
fake.reset()
result = jev.decide(STATE, QUESTIONS)
sent = fake.requests[0] if fake.requests else {}
check("one request, to <base>/systemone", len(fake.requests) == 1 and sent.get("path") == "/v1/systemone")
check("the key goes as a bearer token", sent.get("auth") == f"Bearer {KEY}")
check("the pinned model, the state and the questions are sent as given",
      sent.get("body") == {"model": "jev-1.14.0", "state": STATE, "questions": QUESTIONS})
check("the answer has a call id, the model, every answer and the usage",
      len(result.get("call_id", "")) == 12 and result.get("model") == "jev-1.14.0"
      and set(result.get("answers", {})) == set(QUESTIONS) and result.get("usage", {}).get("input_tokens") == 120)
log = LOG.read_text() if LOG.exists() else ""
check("the call log has the id, the size and the outcome",
      f"call={result.get('call_id')} questions=3 status=ok model=jev-1.14.0 input_tokens=120" in log)
check("the call log holds nothing of the text, the questions or the answers",
      "canary-text" not in log and "backup" not in log and "Routine" not in log and "0.91" not in log)
check("the call log is readable by its owner only", LOG.exists() and (LOG.stat().st_mode & 0o077) == 0)

# Every check that stops a request before it's sent.
cases = {
    "an unknown question type": ({"q": {"type": "box", "instructions": "Where?"}}, "type must be noul, choice or score"),
    "a choice without criteria": ({"q": {"type": "choice", "instructions": "Which?"}}, "choice criteria"),
    "a score with 11 levels": ({"q": {"type": "score", "criteria": [str(i) for i in range(11)]}}, "1 to 10 levels"),
    "noul criteria with other keys": ({"q": {"type": "noul", "criteria": {"yes": "x"}}}, "noul criteria"),
    "a key Jev doesn't take": ({"q": {"type": "noul", "assets": {}}}, "keys Jev doesn't take"),
    "17 questions": ({f"q{i}": {"type": "noul"} for i in range(17)}, "at most 16 questions"),
    "a bad question name": ({"1st": {"type": "noul"}}, "names are letters"),
    "no questions": ({}, "questions must be an object"),
    "instructions too long": ({"q": {"type": "noul", "instructions": "x" * 2001}}, "over 2000 characters"),
    "an empty criterion": ({"q": {"type": "score", "criteria": ["Low", " "]}}, "non-empty string"),
}
fake.reset()
for what, (questions, expect) in cases.items():
    why = refused(STATE, questions)
    check(f"refused before sending: {what}", why is not None and expect in why)
check("none of them reached Jev", not fake.requests)
check("an empty state is refused", "state is empty" in (refused("  ", QUESTIONS) or ""))
check("a state over 60,000 characters is refused", "at most 60000" in (refused("x" * 60001, QUESTIONS) or ""))
check("a state that isn't text or JSON is refused", "state must be" in (refused(42, QUESTIONS) or ""))
check("a JSON state is accepted", refused({"alert": "disk full", "host": "nas"}, QUESTIONS) is None)

# Secrets never go.
fake.reset()
secrets_in = {
    "a private key": "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n",
    "an Anthropic key": "use sk-ant-api03-" + "a" * 40,
    "a GitHub token": "token ghp_" + "b" * 36,
    "an age key": "AGE-SECRET-KEY-1" + "Q" * 58,
    "a password": "the db password: hunter2hunter2",
}
for what, state in secrets_in.items():
    why = refused(state, QUESTIONS)
    check(f"refused: a state holding {what}", why is not None and "never goes to Jev" in why)
check("a secret in a question is refused too",
      "never goes to Jev" in (refused(STATE, {"q": {"type": "noul", "instructions": "Is ghp_" + "c" * 36 + " valid?"}}) or ""))
check("no secret reached Jev", not fake.requests)
check("refusals are logged without content", "status=refused" in LOG.read_text() and "hunter2" not in LOG.read_text())

# Rate limits, errors and the key.
fake.reset(throttle=1)
check("a 429 is retried after its Retry-After", refused(STATE, QUESTIONS) is None and len(fake.requests) == 2)
fake.reset(throttle=5)
why = refused(STATE, QUESTIONS) or ""
check("a 429 that won't clear gives up after two retries", "HTTP 429" in why and len(fake.requests) == 3)
fake.reset(mode="unauthorized")
why = refused(STATE, QUESTIONS) or ""
check("an error that echoes the key doesn't repeat it", "HTTP 401" in why and KEY not in why)
check("errors carry the call id", "(call " in why)
check("an ordinary refusal isn't logged as billing", "reason=" not in LOG.read_text().splitlines()[-1])
fake.reset(mode="billing")
why = refused(STATE, QUESTIONS) or ""
check("running out of credit is an error that says so", "HTTP 402" in why)
check("and the call log marks it reason=billing", LOG.read_text().splitlines()[-1].endswith("status=refused reason=billing"))
key, os.environ["JEV_API_KEY"] = os.environ["JEV_API_KEY"], ""
check("without a key nothing is sent", "no JEV_API_KEY" in (refused(STATE, QUESTIONS) or ""))
os.environ["JEV_API_KEY"] = key
base, jev.BASE_URL = jev.BASE_URL, "http://jev.example.com/v1"
check("a plain-HTTP endpoint off loopback is refused", "must be HTTPS" in (refused(STATE, QUESTIONS) or ""))
jev.BASE_URL = base

# Over stdio, as Hermes starts it.
fake.reset()
env = {"PATH": os.environ.get("PATH", ""), "HOME": str(TMP), "JEV_API_KEY": KEY, "JEV_BASE_URL": BASE,
       "JEV_CALL_LOG": str(TMP / "stdio.log"), "JEV_DEADLINE": "10"}
proc = subprocess.Popen([sys.executable, "-I", str(SERVER)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE, text=True, env=env)
replies = queue.Queue()
threading.Thread(target=lambda: [replies.put(line) for line in proc.stdout], daemon=True).start()


def send(obj):
    proc.stdin.write(json.dumps(obj) + "\n")
    proc.stdin.flush()


def wait_for(msg_id, timeout=20):
    while True:
        try:
            msg = json.loads(replies.get(timeout=timeout))
        except queue.Empty:
            return None
        if msg.get("id") == msg_id:
            return msg


from mcp.types import LATEST_PROTOCOL_VERSION  # noqa: E402

send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
    "protocolVersion": LATEST_PROTOCOL_VERSION, "capabilities": {}, "clientInfo": {"name": "test", "version": "1"}}})
init = wait_for(1)
send({"jsonrpc": "2.0", "method": "notifications/initialized"})
send({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
listed = wait_for(2)
send({"jsonrpc": "2.0", "id": 3, "method": "tools/call",
      "params": {"name": "decide", "arguments": {"state": STATE, "questions": QUESTIONS}}})
called = wait_for(3)
send({"jsonrpc": "2.0", "id": 4, "method": "tools/call",
      "params": {"name": "decide", "arguments": {"state": STATE, "questions": {"q": {"type": "bogus"}}}}})
bad = wait_for(4)
proc.stdin.close()
try:
    proc.wait(timeout=10)
except subprocess.TimeoutExpired:
    proc.kill()
stderr = proc.stderr.read()

check("it answers initialize", bool(init) and init.get("result", {}).get("serverInfo", {}).get("name") == "jev")
tools = (listed or {}).get("result", {}).get("tools", [])
check("it lists one tool, decide, marked read-only",
      [t["name"] for t in tools] == ["decide"] and tools[0].get("annotations", {}).get("readOnlyHint") is True)
check("its schema asks for state and questions",
      set(tools[0].get("inputSchema", {}).get("required", [])) == {"state", "questions"} if tools else False)
content = (called or {}).get("result", {})
text = (content.get("content") or [{}])[0].get("text", "")
try:
    payload = json.loads(text)
except ValueError:
    payload = {}
check("a call over stdio returns the answers with a call id",
      not content.get("isError") and set(payload.get("answers", {})) == set(QUESTIONS) and len(payload.get("call_id", "")) == 12)
check("its call id is in the call log", payload.get("call_id", "?") in (TMP / "stdio.log").read_text())
bad_result = (bad or {}).get("result", {})
check("a bad call comes back as a tool error saying why",
      bad_result.get("isError") is True and "type must be" in json.dumps(bad_result))
check("the key never appears in what the server printed",
      KEY not in stderr and KEY not in json.dumps([init, listed, called, bad]))

httpd.shutdown()
if failures:
    sys.exit(f"{len(failures)} check(s) failed")
print("all checks passed")
