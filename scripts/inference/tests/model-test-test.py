#!/usr/bin/env python3
"""Runs model-test.py against a fake llama-server behind a fake nginx.

The fake answers the way llama-server does with --jinja: whole or streamed,
reasoning in reasoning_content, tool calls with their arguments split over
several chunks, usage and timings, and a 400 for a prompt over a slot's 64K
tokens. Like nginx, it wants a bearer key and lets one key have 2 requests at
a time, answering 429 with Retry-After over that. Tool requests have to look
like Hermes': chat-completions tools, no tool_choice or parallel_tool_calls,
and a result for every call.

It checks that a good model passes every scenario, with the canary in every
prompt and the key never printed or saved; that a bad one (broken tool calls,
a loop, a call left in the text, a server that truncates instead of refusing)
fails; and that a missing or wrong key stops the run before any prompt is
sent.

usage: model-test-test.py <model-test.py>
"""
import importlib.util
import json
import os
import pathlib
import re
import secrets
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SCRIPT = sys.argv[1]
KEY = "inference-mac-" + "5e" * 16
WRONG = "inference-wrong-" + "77" * 12
N_CTX = 65536
SCENARIOS = ["tools", "summary", "triage", "memory", "voice", "voice-load", "refusal", "reasoning", "throughput"]


def fn(name, required, **props):
    """A tool in the Responses API's format, as Hermes may dump it."""
    return {"type": "function", "name": name, "description": f"The {name} tool.", "strict": False,
            "parameters": {"type": "object", "properties": {k: {"type": v} for k, v in props.items()},
                           "required": required}}


HERMES_REQUEST = {
    "model": "gpt-6.1-terra",
    "input": [{"role": "user", "content": "hello"}],
    "tools": [
        fn("terminal", ["command"], command="string", timeout="integer"),
        fn("read_file", ["path"], path="string", offset="integer", limit="integer"),
        fn("web_search", ["query"], query="string"),
        fn("memory", ["action", "target"], action="string", target="string", content="string"),
        {"type": "web_search_preview"},
    ],
}


PC = "mcp__paperclip__paperclip"
GET, LIST, ADD, UPDATE, INBOX = (PC + x for x in ("GetIssue", "ListComments", "AddComment", "UpdateIssue", "InboxLite"))

# The researcher's tools as Hermes dumped them for Codex: memory, and the bridge
# to everything else, with the catalog in the search tool's description.
BRIDGE_REQUEST = {
    "model": "gpt-6.1-terra",
    "input": [{"role": "user", "content": "hello"}],
    "tools": [
        fn("memory", ["target"], action="string", target="string", content="string"),
        fn("hermes_tool_search", ["queries"], queries="array", limit="integer"),
        fn("tool_describe", ["names"], names="array"),
        fn("tool_call", ["calls"], calls="array"),
    ],
}
BRIDGE_REQUEST["tools"][1]["description"] = (
    "Search 7 additional tools that are loaded on demand.\n\nDeferred tool catalog (call schemas via "
    "`tool_describe`, invoke via `tool_call`):\npaperclip tools (6):\n"
    + "".join(f"- {PC}{n}: {d}\n" for n, d in [
        ("AddComment", "Add a comment to an issue; include resume=true when…"),
        ("CheckoutIssue", "Checkout an issue for an agent"), ("GetIssue", "Get a single issue by UUID or identifier"),
        ("InboxLite", "Get the current authenticated agent inbox-lite assignment…"),
        ("ListComments", "List issue comments with incremental options"),
        ("UpdateIssue", "Patch an issue, optionally including a comment; include…")])
    + "session_search tools (1):\n- session_search: Recall past conversations: search or read old Hermes…\n")


def chunk(delta, finish=None):
    return {"id": "chatcmpl-1", "object": "chat.completion.chunk", "model": "local",
            "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}


def timings(n, completion, per_second=95.0):
    return {"prompt_n": n, "prompt_ms": n / 2.0, "prompt_per_second": 2000.0, "predicted_n": completion,
            "predicted_ms": completion / per_second * 1000, "predicted_per_second": per_second}


def tokens(body):
    chars = sum(len(m.get("content") or "") for m in body["messages"]) + len(json.dumps(body.get("tools") or []))
    return chars // 4 + 12


class Fake:
    def __init__(self):
        self.lock = threading.Lock()
        self.reset()

    def reset(self, bad=False):
        # bad: the model's tool calls go wrong, and long prompts are truncated
        # instead of refused.
        self.bad = bad
        self.inflight = 0
        self.requests = []
        self.bodies = []
        self.throttled = 0
        self.problems = []

    def admit(self, method, path, auth):
        """nginx's part: the key, and 2 requests at a time per key."""
        with self.lock:
            self.requests.append((method, path, auth))
            if auth != f"Bearer {KEY}":
                return ("json", 401, {"error": {"message": "Unauthorized", "type": "authentication_error"}}, {}), False
            if path not in ("/v1/chat/completions", "/v1/models"):
                return ("json", 404, {"error": {"message": "Not found"}}, {}), False
            if self.inflight >= 2:
                self.throttled += 1
                return ("json", 429, {"error": {"message": "Too many requests", "type": "rate_limit_error",
                                                "code": 429}}, {"Retry-After": "1"}), False
            self.inflight += 1
            return None, True

    def release(self):
        with self.lock:
            self.inflight -= 1

    def respond(self, method, path, body):
        if path == "/v1/models":
            assert method == "GET", method
            return ("json", 200, {"object": "list", "data": [{"id": "local", "object": "model", "owned_by": "llamacpp",
                                                              "meta": {"n_ctx_train": 131072}}]}, {})
        assert method == "POST", method
        assert body.get("model") == "local", body.get("model")
        with self.lock:
            self.bodies.append(json.dumps(body))
        n = tokens(body)
        if n > N_CTX and not self.bad:
            return ("json", 400, {"error": {"code": 400, "type": "exceed_context_size_error",
                                            "message": "the request exceeds the available context size, try increasing it",
                                            "n_prompt_tokens": n, "n_ctx": N_CTX}}, {})
        if n > 40000:
            time.sleep(1.5)  # a long prefill
            return self.reply("The keeper kept the light.", min(n, N_CTX))
        msgs = body["messages"]
        system = msgs[0]["content"] if msgs[0]["role"] == "system" else ""
        last = msgs[-1].get("content") or ""
        if body.get("tools"):
            self.check_tools(body)
            return self.voice(body, n) if "Home Assistant" in system else self.agent(body, n)
        assert not body.get("stream"), "only tool requests are streamed"
        if "Summary:" in last:
            return self.reply("Summary:\nThe work day moved from 7 March to Saturday 14 March, 9am, and the committee "
                              "took Brookfield's $1,240 quote for the new tank.\n\nReply:\nHi Dev, yes, I'll bring "
                              "the trailer on the 14th and take the old tank to the tip.\n\nSam", n)
        if "most_urgent" in last:
            if "A2" in last:
                obj = {"most_urgent": "A2", "needs_human": True, "severity": "critical",
                       "reason": "The backup disk is nearly full and failing."}
            else:
                obj = {"most_urgent": None, "needs_human": False, "severity": "info",
                       "reason": "Everything has resolved or renews itself."}
            return self.reply(json.dumps(obj), n)
        if '"write"' in last:
            if "drafts" in last:
                obj = {"write": True, "content": "Open pull requests as drafts; the operator marks them ready.",
                       "reason": "A lasting preference."}
            else:
                obj = {"write": False, "content": None, "reason": "Nothing that lasts."}
            return self.reply("```json\n" + json.dumps(obj, indent=2) + "\n```", n)
        if "train leaves" in last:
            high = (body.get("chat_template_kwargs") or {}).get("reasoning_effort") == "high"
            return self.reply("131", n, reasoning="Moving time is the trip less the stops. " * (60 if high else 6))
        if "day in the life" in last:
            time.sleep(0.3)
            return self.reply("The keeper rose before dawn. " * 55, n, completion=400)
        return self.reply("OK", n)

    @staticmethod
    def reply(content, n, reasoning="", completion=None):
        completion = completion or max(1, (len(content) + len(reasoning)) // 4)
        message = {"role": "assistant", "content": content}
        if reasoning:
            message["reasoning_content"] = reasoning
        return ("json", 200, {"id": "chatcmpl-1", "object": "chat.completion", "model": "local",
                              "choices": [{"index": 0, "message": message, "finish_reason": "stop"}],
                              "usage": {"prompt_tokens": n, "completion_tokens": completion,
                                        "total_tokens": n + completion},
                              "timings": timings(n, completion)}, {})

    @staticmethod
    def check_tools(body):
        assert body.get("stream") is True and body.get("stream_options") == {"include_usage": True}, \
            "tool requests are streamed, with usage"
        assert "tool_choice" not in body and "parallel_tool_calls" not in body, \
            "Hermes never sends tool_choice or parallel_tool_calls"
        for t in body["tools"]:
            assert set(t) == {"type", "function"} and t["type"] == "function", f"not a chat-completions tool: {t}"
            assert isinstance(t["function"].get("name"), str) and isinstance(t["function"].get("parameters"), dict), t
        made = set()
        for m in body["messages"]:
            for call in m.get("tool_calls") or []:
                assert isinstance(call["function"]["arguments"], str), call
                made.add(call["id"])
            if m["role"] == "tool":
                assert m.get("tool_call_id") in made, "a tool result for a call that wasn't made"

    def agent(self, body, n):
        msgs = body["messages"]
        names = {t["function"]["name"] for t in body["tools"]}
        if "tool_call" in names:
            return self.bridged(body, n, names)
        task = msgs[1]["content"]
        step = sum(1 for m in msgs if m["role"] == "assistant")
        results = [m["content"] for m in msgs if m["role"] == "tool"]
        if self.bad and "disk-policy" in task:
            # A call the server didn't parse, left in the text.
            return self.stream(n, content='<tool_call>{"name": "terminal", "arguments": {"command": "df -h /"}}</tool_call>')
        if self.bad:
            missing = {"path": "/srv/notes/missing.md"}
            plan = [[("read_file", '{"path": "/srv/notes/inference.md"')], [("browse_web", {"url": "https://example.org"})],
                    [("memory", {})], [("read_file", missing)], [("read_file", missing)], [("read_file", missing)]]
            final = "I couldn't finish."
            if step == 1:
                assert "Invalid tool call" in results[-1], results
        elif "/srv/notes/inference.md" in task:
            plan = [[("read_file", {"path": "/srv/notes/inference.md"})],
                    [("web_search", {"query": "llama.cpp b9608 release date"})],
                    [("memory", {"action": "add", "target": "memory",
                                 "content": "The inference host runs llama.cpp b9608, released 21 October 2026."})]]
            final = "The server runs llama.cpp b9608, which was released on 21 October 2026. I saved that to memory."
            # The results fed back have to be the task's file and search.
            if step == 1:
                assert "b9608" in results[-1], results
            if step == 2:
                assert "21 October 2026" in results[-1], results
        elif "disk-policy" in task:
            # Two calls in one turn.
            plan = [[("terminal", {"command": "df -h /"}), ("read_file", {"path": "/srv/notes/disk-policy.md"})],
                    [("memory", {"action": "add", "target": "memory",
                                 "content": "The root filesystem was 89% full, over the 85% policy."})]]
            final = "The root filesystem is 89% full, which is over the policy's 85% limit, so I saved a memory."
            if step == 1:
                assert "89%" in results[-2] and "85%" in results[-1], results
        else:
            raise AssertionError(f"a task the fake doesn't know: {task[:80]}")
        if step < len(plan):
            if not self.bad:
                assert all(name in names for name, _ in plan[step]), names
            return self.stream(n, calls=plan[step])
        return self.stream(n, content=final)

    def bridged(self, body, n, names):
        """The researcher working Paperclip issues through Hermes' bridge."""
        assert "tool_search" in names and "hermes_tool_search" not in names, \
            "over chat completions the bridge's search tool is tool_search"
        msgs = body["messages"]
        task = msgs[1]["content"]
        step = sum(1 for m in msgs if m["role"] == "assistant")
        results = [m["content"] for m in msgs if m["role"] == "tool"]
        one = lambda name, args: [("tool_call", {"calls": [{"name": name, "arguments": args}]})]
        if self.bad:
            plan = [[("tool_call", {"calls": [{"name": GET, "arguments": {"issueId": "LAB-31"}},
                                              {"name": LIST, "arguments": {"issueId": "LAB-31"}}]})],
                    one(PC + "GetTicket", {"issueId": "LAB-31"}), one(GET, {"id": "LAB-31"})]
            final = "I couldn't read LAB-31."
            if step == 1:
                assert "exactly one entry" in results[-1], results
        elif "LAB-31" in task:
            plan = [[("tool_search", {"queries": ["paperclip get issue", "paperclip add comment"]})],
                    [("tool_describe", {"names": [GET, LIST, ADD, UPDATE]})],
                    one(GET, {"issueId": "LAB-31"}), one(LIST, {"issueId": "LAB-31"}),
                    one(ADD, {"issueId": "LAB-31", "body": "Whisper listens on port 10300."}),
                    one(UPDATE, {"issueId": "LAB-31", "status": "done"})]
            final = "I answered on LAB-31 that Whisper listens on port 10300, and marked it done."
            if step == 1:
                assert GET in results[-1] and ADD in results[-1], results
            if step == 2:
                assert '"issueId"' in results[-1], results
            if step == 3:
                assert "Whisper" in results[-1], results
            if step == 4:
                assert "10300" in results[-1], results
        elif "LAB-32" in task:
            # Straight from the catalog, without a search or a describe.
            plan = [one(GET, {"issueId": "LAB-32"}), one("session_search", {"query": "nightly backups start time"}),
                    one(ADD, {"issueId": "LAB-32", "body": "The nightly backups start at 02:30."})]
            final = "The nightly backups start at 02:30; I said so in a comment on LAB-32."
            if step == 2:
                assert "02:30" in results[-1], results
        elif "inbox" in task:
            plan = [one(INBOX, {})]
            final = "LAB-35, backups failing on nas-disk-2, is the most urgent."
            if step == 1:
                assert "LAB-35" in results[-1], results
        else:
            raise AssertionError(f"a task the fake doesn't know: {task[:80]}")
        if step < len(plan):
            return self.stream(n, calls=plan[step])
        return self.stream(n, content=final)

    def voice(self, body, n):
        said = body["messages"][-1]["content"].lower()
        if "kitchen" in said:
            call = ("HassTurnOn", {"name": "Kitchen Lights", "domain": ["light"]})
        elif "living room" in said:
            call = ("HassClimateSetTemperature", {"area": "Living Room", "temperature": 21})
        else:
            call = ("HassLightSet", {"name": "Bedroom Lamp", "brightness": 30})
        return self.stream(n, calls=[call])

    @staticmethod
    def stream(n, calls=(), content=""):
        out = [(0.0, chunk({"role": "assistant", "content": None})),
               (0.05, chunk({"reasoning_content": "Let me "})), (0.01, chunk({"reasoning_content": "think."}))]
        for piece in (content[: len(content) // 2], content[len(content) // 2:]):
            if piece:
                out.append((0.01, chunk({"content": piece})))
        for i, (name, args) in enumerate(calls):
            raw = args if isinstance(args, str) else json.dumps(args)
            out.append((0.01, chunk({"tool_calls": [{"index": i, "id": f"call_{secrets.token_hex(4)}",
                                                      "type": "function", "function": {"name": name, "arguments": ""}}]})))
            third = max(1, len(raw) // 3)
            for piece in (raw[:third], raw[third: 2 * third], raw[2 * third:]):
                if piece:
                    out.append((0.01, chunk({"tool_calls": [{"index": i, "function": {"arguments": piece}}]})))
        completion = 20
        last = chunk({}, "tool_calls" if calls else "stop")
        last["timings"] = timings(n, completion)
        out.append((0.01, last))
        out.append((0.0, {"id": "chatcmpl-1", "object": "chat.completion.chunk", "choices": [],
                          "usage": {"prompt_tokens": n, "completion_tokens": completion, "total_tokens": n + completion}}))
        return ("sse", out)


def serve(fake):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def respond(self):
            path = urllib.parse.urlsplit(self.path).path
            length = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(length)) if length else None
            plan, admitted = fake.admit(self.command, path, self.headers.get("Authorization") or "")
            try:
                if plan is None:
                    try:
                        plan = fake.respond(self.command, path, body)
                    except AssertionError as err:
                        with fake.lock:
                            fake.problems.append(str(err))
                        print(f"fake refused: {err}")
                        plan = ("json", 500, {"error": {"message": f"fake refused: {err}"}}, {})
                self.write(plan)
            finally:
                if admitted:
                    fake.release()

        def write(self, plan):
            if plan[0] == "json":
                _, status, obj, headers = plan
                data = json.dumps(obj).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                for k, v in headers.items():
                    self.send_header(k, v)
                self.end_headers()
                self.wfile.write(data)
                return
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            for delay, obj in plan[1]:
                time.sleep(delay)
                self.wfile.write(f"data: {json.dumps(obj)}\n\n".encode())
                self.wfile.flush()
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()

        do_GET = do_POST = respond

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


fake = Fake()
server = serve(fake)
url = f"http://127.0.0.1:{server.server_address[1]}/v1"
tmp = pathlib.Path(tempfile.mkdtemp())
tools_path = tmp / "hermes-request.json"
tools_path.write_text(json.dumps(HERMES_REQUEST))
bridge_path = tmp / "hermes-bridge.json"
bridge_path.write_text(json.dumps(BRIDGE_REQUEST))


def run(*extra, key=KEY):
    env = {k: v for k, v in os.environ.items() if k != "INFERENCE_KEY" and not k.lower().endswith("_proxy")}
    if key is not None:
        env["INFERENCE_KEY"] = key
    proc = subprocess.run([sys.executable, "-I", SCRIPT, "--url", url, *extra],
                          capture_output=True, text=True, env=env, timeout=300)
    output = proc.stdout + proc.stderr
    print(output)
    return proc.returncode, output


failures = []


def check(what, ok):
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        failures.append(what)


# A model that does everything right.
good = tmp / "good.json"
code, out = run("--label", "fake-good", "--repeat", "2", "--load-delay", "0.3", "--tools", str(tools_path),
                "--out", str(good))
report = json.loads(good.read_text()) if good.exists() else {"results": [], "canary": None}
by = {r["scenario"]: r for r in report["results"]}
canary = report["canary"]
check("a good model passes, and the run exits 0",
      code == 0 and all(r["status"] in ("PASS", "INFO") for r in report["results"]))
check("every scenario ran", list(by) == SCENARIOS)
check("the fake saw nothing it refused", not fake.problems)
check("Responses API tools are converted and the rest skipped", "skipped 1 that aren't: web_search_preview" in out)
tools = by.get("tools", {})
check("tools: 6 calls over 2 conversations, all valid, no loop",
      (tools.get("calls"), tools.get("valid"), tools.get("loops")) == (6, 6, 0) and tools.get("status") == "PASS")
check("tools: both conversations finished with the right answer", (tools.get("finished"), tools.get("correct")) == (2, 2))
check("tools: two calls in one turn are both counted",
      [len(r["calls"]) for r in tools.get("runs", [])] == [3, 3] and [r["turns"] for r in tools.get("runs", [])] == [4, 3])
check("summary, triage and memory pass", all(by.get(s, {}).get("status") == "PASS" for s in ("summary", "triage", "memory")))
check("memory finds JSON in a fenced answer", [r.get("how") for r in by.get("memory", {}).get("runs", [])] == ["wrapped"] * 2)
voice = by.get("voice", {}).get("runs", [])
check("voice: timed to the first tool-call token, after the reasoning",
      len(voice) == 2 and all(0 < r["first_any"] < r["first_token"] < r["done"] < 1.5 and r["right"] for r in voice))
loaded = by.get("voice-load", {})
check("voice-load: the voice request ran during the long prompt",
      loaded.get("status") == "PASS" and all(r.get("overlapped") for r in loaded.get("runs", []))
      and all(r["load"].get("prompt_tokens", 0) > 45000 for r in loaded.get("runs", [])))
check("calibration finds 0.25 tokens per character", abs(report.get("calibration", {}).get("tokens_per_char", 0) - 0.25) < 0.01)
refusal = by.get("refusal", {})
check("refusal: a 400 for over 64K counts as refused",
      refusal.get("status") == "PASS" and all(r["refused"] and r["n_prompt_tokens"] > N_CTX for r in refusal.get("runs", [])))
check("reasoning: chat_template_kwargs changed it, reasoning_effort didn't",
      by.get("reasoning", {}).get("changed") == {"chat_template_kwargs": True, "reasoning_effort": False})
throughput = by.get("throughput", {})
check("throughput: 429s are waited out and counted",
      throughput.get("throttled", 0) > 0 and throughput.get("failed") == 0
      and sum(r.get("throttled", 0) for r in report["results"]) == fake.throttled)
check("throughput: the 4-at-once rounds took the Retry-After wait",
      all(rd["seconds"] >= 1.0 for rd in throughput.get("runs", {}).get("4", [])))
check("the canary is in every prompt", bool(canary) and fake.bodies and all(canary in b for b in fake.bodies))
check("the canary and the command to look for it are printed at the end",
      bool(canary) and canary in out.strip().splitlines()[-1] and "ssh inference" in out.strip().splitlines()[-1])
check("every request carried the key", fake.requests and all(auth == f"Bearer {KEY}" for _, _, auth in fake.requests))
check("the key is never printed or saved", KEY not in out and KEY not in good.read_text())

# A model whose tool calls go wrong, on a server that truncates long prompts.
fake.reset(bad=True)
bad = tmp / "bad.json"
code, out = run("--label", "fake-bad", "--only", "tools,refusal", "--repeat", "2", "--tools", str(tools_path),
                "--out", str(bad))
report = json.loads(bad.read_text()) if bad.exists() else {"results": []}
by = {r["scenario"]: r for r in report["results"]}
tools = by.get("tools", {})
check("a bad model fails, and the run exits 1", code == 1)
check("tools: counts 4 invalid calls and the loop",
      (tools.get("calls"), tools.get("valid"), tools.get("loops"), tools.get("status")) == (7, 3, 1, "FAIL"))
check("tools: a tool call left in the text isn't a finished answer", tools.get("finished") == 0)
check("tools: says why each call was invalid",
      all(any(why in note for note in tools.get("notes", [])) for why in
          ("its arguments aren't JSON", "there's no tool called 'browse_web'", "memory is missing action, target",
           "a tool call left in the answer's text")))
check("refusal: an answer to a truncated prompt fails",
      by.get("refusal", {}).get("status") == "FAIL" and "truncated" in " ".join(by.get("refusal", {}).get("notes", [])))

# The researcher's real tools: the bridge, and Paperclip issues behind it.
fake.reset()
bridged = tmp / "bridged.json"
code, out = run("--label", "fake-bridge", "--only", "tools", "--repeat", "3", "--tools", str(bridge_path),
                "--out", str(bridged))
report = json.loads(bridged.read_text()) if bridged.exists() else {"results": []}
tools = {r["scenario"]: r for r in report["results"]}.get("tools", {})
runs = tools.get("runs", [])
check("bridge: a good model passes", code == 0 and tools.get("status") == "PASS" and not fake.problems)
check("bridge: says it found the bridge and the catalog behind it",
      "Hermes' on-demand bridge, with 7 tools behind it" in out)
check("bridge: 10 calls over the 3 issue tasks, all valid and right",
      (tools.get("calls"), tools.get("valid"), tools.get("correct")) == (10, 10, 3))
check("bridge: the comment and the status change were recorded",
      len(runs) == 3 and {(w["issue"], w["what"]) for w in runs[0].get("writes", [])} >= {("LAB-31", "comment"), ("LAB-31", "status")}
      and not runs[2].get("writes"))
fake.reset(bad=True)
code, out = run("--label", "fake-bridge-bad", "--only", "tools", "--repeat", "1", "--tools", str(bridge_path),
                "--out", str(tmp / "bridged-bad.json"))
report = json.loads((tmp / "bridged-bad.json").read_text())
tools = {r["scenario"]: r for r in report["results"]}.get("tools", {})
check("bridge: a bad model fails, with 2 invalid calls, a batch and a wrong answer",
      code == 1 and (tools.get("calls"), tools.get("valid"), tools.get("correct")) == (3, 1, 0))
check("bridge: says why each call was invalid, and notes the batch",
      all(any(why in note for note in tools.get("notes", [])) for why in
          ("a batch of local tools in one tool_call", "doesn't exist", "GetIssue is missing issueId")))

# No key, then the wrong one.
fake.reset()
code, out = run("--only", "summary", "--out", str(tmp / "none.json"), key=None)
check("without INFERENCE_KEY it stops before sending anything", code != 0 and "INFERENCE_KEY" in out and not fake.requests)
code, out = run("--only", "summary", "--out", str(tmp / "wrong.json"), key=WRONG)
check("a refused key stops it before any prompt, without printing the key",
      code != 0 and "refused the key (HTTP 401)" in out and WRONG not in out and not fake.bodies)

server.shutdown()

# Each candidate's way of leaving a call or its thinking in the text.
spec = importlib.util.spec_from_file_location("model_test", SCRIPT)
mt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mt)
names = ["web_search"]
check("a Gemma 4 call left in the text is caught",
      mt.leaked_call('<|tool_call>call:web_search{query:<|"|>x<|"|>}<tool_call|>', names))
check("a Qwen call left in the text is caught",
      mt.leaked_call("<tool_call>\n<function=web_search>\n<parameter=query>\nx\n</parameter>\n</function>\n</tool_call>", names))
check("a gpt-oss call left in the text is caught", mt.leaked_call("<|channel|>commentary to=functions.web_search", names))
check("plain prose isn't a leaked call", not mt.leaked_call("The search found three results.", names))
bridge = mt.Bridge("tool_search", {})
result, why = bridge.call({"calls": [{"name": ADD, "arguments": {"issueId": "LAB-32", "body": {"text": "02:30"}}}]})
check("bridge: an object where text belongs is refused with the schema, not a crash",
      why == "tool_call: AddComment's body is not of type 'string'" and "parameters" in result and not bridge.writes)
result, why = bridge.call({"calls": [{"name": GET, "arguments": {"issue_id": "LAB-31"}}]})
check("bridge: a missing argument gets Hermes' error, with the schema and a hint",
      why == "tool_call: GetIssue is missing issueId" and "NOT invoked" in result["error"]
      and result["parameters"]["required"] == ["issueId"] and "hint" in result)
result, why = bridge.call({"calls": [{"name": UPDATE, "arguments": {"issueId": "LAB-31", "status": "closed"}}]})
check("bridge: a status that isn't one of the enum is refused", why is not None and "is not one of" in why)
check("bridge: an answer with a non-breaking hyphen still names the issue",
      bridge.right(mt.BRIDGE_TASKS[2], "The most urgent is **LAB\u201135**."))
check("a price with a narrow space as the thousands separator is found",
      re.search(mt.SUMMARY_FACTS["the $1,240 quote"], mt.fold("approved at $1\u202f240")) is not None)
check("thinking left in the text is counted, Qwen's and Gemma 4's",
      mt.think_length({"reasoning": "ab", "content": "<think>xyz</think>a<|channel>thought\nwxyz<channel|>b"}) == 2 + 3 + 5)

if failures:
    sys.exit(f"{len(failures)} check(s) failed")
print("all checks passed")
