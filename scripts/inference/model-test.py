#!/usr/bin/env python3
"""Tests the model llama-server is serving as `local`, run from the Mac.

Phase 3.1 picks one model for the RTX 3090. Each candidate gets its own
deployment, and this runs once against each, with the mac key, through the
OpenAI-compatible API at inference.servicestack.xyz. It runs each of these
--repeat times:

  tools       a Hermes-shaped agent loop: chat-completions tools, streamed,
              with scripted tool results fed back for up to --max-turns turns.
              A call is valid when its arguments parse as a JSON object, the
              tool exists and its required parameters are there. The same
              call three times running is a loop. When the tools are Hermes'
              on-demand bridge (tool_search, tool_describe, tool_call), as
              the researcher's are, the tasks are Paperclip issues worked
              through it, the bridge answers as Hermes does, and a run is
              right when both the answer and the changes to the issues are.
  summary     a long synthetic email thread to summarise and reply to, checked
              for the facts that matter
  triage      a few synthetic alerts: which is urgent, and does it need a
              human, as JSON
  memory      background review's question, "is anything here worth saving
              to memory?", which has to come back as JSON
  voice       a Home Assistant device command with HA-style tools, streamed and
              timed to the first token of the answer or tool call
  voice-load  the same while another request sends about 50K tokens of prompt
  refusal     a prompt over 64K tokens, which the server has to refuse with an
              error rather than answer from a truncated prompt
  reasoning   one question with the server's reasoning default, then with
              chat_template_kwargs and with reasoning_effort in the request,
              and whether either changed anything
  throughput  tokens per second with 1 and with 4 requests at once

Targets: at least 95% of tool calls valid with no loops and every agent
run right, and voice's first token within 1.5 s alone and 4 s under load, on
the slowest run. The other scenarios pass when every run gets its checks
right; reasoning and throughput only report. A 429 from nginx is retried
after its Retry-After, and counted.

Every prompt is synthetic and carries a canary that's new each run. The canary
is printed at the end with the command that searches the host for it, which
should find nothing.

The key comes from INFERENCE_KEY and is never printed:

  export INFERENCE_KEY="$(sops -d --extract '["inference"]["keys"]["mac"]' secrets/hosts/inference.yaml)"

nginx lets one key make 2 requests at a time, so through it "4 at once" shows
the cap. For the GPU's own figure, open a tunnel to llama-server with
`ssh -N -L 8080:127.0.0.1:8080 inference` and pass
--url http://127.0.0.1:8080/v1 --no-key.

--tools takes the tool schemas from a real Hermes request, either the request
body or just its tools list, in chat-completions or Responses API format.
--ha-tools does the same for Home Assistant's. Without them it uses small
synthetic sets.

It prints a results table and writes everything, answers included, to a JSON
file (--out, by default model-test-<label>-<time>.json in this directory).
It exits 1 when anything failed.

usage:
  scripts/inference/model-test.py --label gpt-oss-20b [--tools hermes-tools.json]
      [--ha-tools ha-tools.json] [--only tools,voice,...] [--repeat 5] [--out FILE]
"""
import argparse
import collections
import datetime
import http.client
import json
import math
import os
import pathlib
import random
import re
import secrets
import statistics
import sys
import threading
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request

SCENARIOS = ["tools", "summary", "triage", "memory", "voice", "voice-load", "refusal", "reasoning", "throughput"]
CONTEXT_PER_SLOT = 65536
# 429s waited out per request, and the longest Retry-After honoured.
MAX_RETRIES = 40
MAX_RETRY_WAIT = 60.0
THROUGHPUT_TOKENS = 512
# Used when the token calibration can't be done: on the low side, so the
# prompt meant to be over 64K still is.
FALLBACK_TOKENS_PER_CHAR = 0.2

SECRETS = []


def scrub(s):
    for secret in SECRETS:
        s = s.replace(secret, "***")
    return s


def say(*parts):
    print(scrub(" ".join(str(p) for p in parts)), flush=True)


DASHES = re.compile("[\u2010-\u2015\u2212]")
SPACES = re.compile("[\u00a0\u2007-\u200a\u202f]")


def fold(s):
    """Text as the checks read it: Unicode dashes and spaces made plain. gpt-oss
    writes LAB\u201135 with a non-breaking hyphen and $1\u202f240 with a narrow space."""
    return SPACES.sub(" ", DASHES.sub("-", str(s or "")))


def text(s, limit=300):
    s = " ".join(str(s).split())
    return s if len(s) <= limit else s[: limit - 1] + "…"


def parse_json(raw):
    try:
        return json.loads(raw)
    except (ValueError, TypeError):
        return None


def error_text(raw):
    """What an error body says, on one line."""
    data = parse_json(raw)
    if isinstance(data, dict):
        err = data.get("error", data)
        if isinstance(err, dict):
            return text(err.get("message") or json.dumps(err), 200)
        return text(err, 200)
    if isinstance(raw, bytes):
        raw = raw.decode("utf-8", "replace")
    return text(raw or "(empty)", 200)


def retry_after(value):
    try:
        return min(max(float(value), 0.1), MAX_RETRY_WAIT)
    except (TypeError, ValueError):
        return 1.0


def secs(x):
    return "n/a" if x is None else f"{x:.2f} s"


def rate(x):
    return "?" if x is None else f"{x:.0f}"


def median(xs):
    xs = [x for x in xs if x is not None]
    return statistics.median(xs) if xs else None


def biggest(xs):
    xs = [x for x in xs if x is not None]
    return max(xs) if xs else None


class Fail(Exception):
    """A request that got no answer. status is the HTTP status, if there was one."""

    def __init__(self, message, status=None, body=None):
        super().__init__(message)
        self.status = status
        self.body = body


class Client:
    def __init__(self, url, key, model, timeout):
        self.base = url.rstrip("/")
        self.host = urllib.parse.urlsplit(self.base).hostname
        self.key = key
        self.model = model
        self.timeout = timeout
        # No proxies: the key only ever goes to the server named in --url.
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        self.lock = threading.Lock()
        self.throttled = 0

    def open(self, method, path, body=None, accept="application/json"):
        """The response, after waiting out any 429s, with when the attempt that
        got through was sent and how many 429s came first."""
        data = None if body is None else json.dumps(body).encode()
        retries = 0
        while True:
            req = urllib.request.Request(self.base + path, data=data, method=method)
            if self.key:
                req.add_header("Authorization", f"Bearer {self.key}")
            req.add_header("Accept", accept)
            req.add_header("User-Agent", "model-test")
            if data is not None:
                req.add_header("Content-Type", "application/json")
            started = time.monotonic()
            try:
                return self.opener.open(req, timeout=self.timeout), started, retries
            except urllib.error.HTTPError as err:
                raw = err.read()
                err.close()
                if err.code == 429 and retries < MAX_RETRIES:
                    retries += 1
                    with self.lock:
                        self.throttled += 1
                    time.sleep(retry_after(err.headers.get("Retry-After")))
                    continue
                raise Fail(f"{method} {path}: HTTP {err.code}: {error_text(raw)}", err.code, parse_json(raw)) from None
            except (urllib.error.URLError, OSError, http.client.HTTPException) as err:
                reason = getattr(err, "reason", None) or err
                raise Fail(f"{method} {path}: couldn't reach {self.host}: {reason}") from None

    def get(self, path):
        resp, _, _ = self.open("GET", path)
        with resp:
            return parse_json(resp.read())

    def chat(self, body):
        """One answer, not streamed."""
        body = {"model": self.model, **body}
        resp, started, retries = self.open("POST", "/chat/completions", body)
        try:
            with resp:
                raw = resp.read()
        except (OSError, http.client.HTTPException) as err:
            raise Fail(f"POST /chat/completions: the answer broke off: {err}") from None
        answer = self.answer(parse_json(raw), raw)
        answer.update(started=started, elapsed=time.monotonic() - started, retries=retries)
        return answer

    @staticmethod
    def answer(data, raw):
        if not isinstance(data, dict) or not data.get("choices"):
            raise Fail(f"POST /chat/completions: an answer with no choices: {error_text(raw)}")
        choice = data["choices"][0]
        message = choice.get("message") or {}
        calls = []
        for call in message.get("tool_calls") or []:
            fn = call.get("function") or {}
            calls.append({"id": call.get("id"), "name": fn.get("name") or "", "arguments": fn.get("arguments")})
        return {"content": message.get("content") or "",
                "reasoning": message.get("reasoning_content") or message.get("reasoning") or "",
                "tool_calls": calls, "finish_reason": choice.get("finish_reason"),
                "usage": data.get("usage") or {}, "timings": data.get("timings") or {},
                "first_any": None, "first_token": None}

    def stream(self, body):
        """One streamed answer, with when its first token came: first_any counts
        reasoning, first_token only the answer or a tool call."""
        body = {"model": self.model, **body, "stream": True, "stream_options": {"include_usage": True}}
        resp, started, retries = self.open("POST", "/chat/completions", body, accept="text/event-stream")
        if "text/event-stream" not in (resp.headers.get("Content-Type") or ""):
            # The server answered all at once.
            with resp:
                raw = resp.read()
            answer = self.answer(parse_json(raw), raw)
            now = time.monotonic() - started
            answer.update(started=started, elapsed=now, retries=retries, first_any=now, first_token=now)
            return answer
        content, reasoning, calls = [], [], {}
        first_any = first_token = finish = None
        usage, timings = {}, {}
        try:
            with resp:
                for raw in resp:
                    line = raw.decode("utf-8", "replace").strip()
                    if line.startswith("error:"):
                        raise Fail(f"POST /chat/completions: error mid-stream: {error_text(line[6:].strip())}")
                    if not line.startswith("data:"):
                        continue
                    data = line[5:].strip()
                    if data == "[DONE]":
                        break
                    chunk = parse_json(data)
                    if not isinstance(chunk, dict):
                        continue
                    if chunk.get("error"):
                        raise Fail(f"POST /chat/completions: error mid-stream: {error_text(data)}")
                    usage = chunk.get("usage") or usage
                    timings = chunk.get("timings") or timings
                    for choice in chunk.get("choices") or []:
                        delta = choice.get("delta") or {}
                        now = time.monotonic() - started
                        r = delta.get("reasoning_content") or delta.get("reasoning")
                        c = delta.get("content")
                        tcs = delta.get("tool_calls") or []
                        if r:
                            reasoning.append(r)
                        if c:
                            content.append(c)
                        for tc in tcs:
                            index = tc.get("index")
                            if index is None:
                                index = len(calls) if tc.get("id") or not calls else max(calls)
                            slot = calls.setdefault(index, {"id": None, "name": "", "arguments": ""})
                            if tc.get("id"):
                                slot["id"] = tc["id"]
                            fn = tc.get("function") or {}
                            if fn.get("name") and fn["name"] != slot["name"]:
                                slot["name"] += fn["name"]
                            if fn.get("arguments"):
                                slot["arguments"] += fn["arguments"]
                        if (r or c or tcs) and first_any is None:
                            first_any = now
                        if (c or tcs) and first_token is None:
                            first_token = now
                        if choice.get("finish_reason"):
                            finish = choice["finish_reason"]
        except (OSError, http.client.HTTPException) as err:
            raise Fail(f"POST /chat/completions: the stream broke off: {err}") from None
        return {"content": "".join(content), "reasoning": "".join(reasoning),
                "tool_calls": [calls[i] for i in sorted(calls)], "finish_reason": finish,
                "usage": usage, "timings": timings, "started": started,
                "elapsed": time.monotonic() - started, "retries": retries,
                "first_any": first_any, "first_token": first_token}


# -- tool schemas --------------------------------------------------------------

def tool(name, description, properties, required=()):
    return {"type": "function", "function": {
        "name": name, "description": description,
        "parameters": {"type": "object", "properties": properties, "required": list(required)}}}


S = {"type": "string"}
I = {"type": "integer"}

# Shaped like Hermes' own tools, for when there's no dump of the real ones.
AGENT_TOOLS = [
    tool("terminal", "Run a shell command on this machine and return its output and exit code.",
         {"command": {**S, "description": "The command to run"},
          "timeout": {**I, "description": "Seconds before it's stopped (default 180)"}}, ["command"]),
    tool("read_file", "Read a text file, with line numbers. Use offset and limit for big files.",
         {"path": {**S, "description": "Absolute path of the file"}, "offset": {**I, "description": "First line, from 1"},
          "limit": {**I, "description": "How many lines"}}, ["path"]),
    tool("web_search", "Search the web. Returns titles, URLs and snippets.",
         {"query": S, "limit": {**I, "description": "How many results (default 5)"}}, ["query"]),
    tool("memory", "Long-term memory, shown at the start of every session. Save durable facts and preferences, "
         "not one-off task details.",
         {"action": {**S, "enum": ["add", "replace", "remove"]}, "target": {**S, "enum": ["memory", "user"]},
          "content": {**S, "description": "The entry to add, or the new text"},
          "old_text": {**S, "description": "For replace and remove: part of the entry to change"}},
         ["action", "target"]),
]

AREA = {"name": S, "area": S, "floor": S, "domain": {"type": "array", "items": S},
        "device_class": {"type": "array", "items": S}}

# Shaped like Home Assistant's intent tools.
HA_TOOLS = [
    tool("HassTurnOn", "Turns on, opens or presses a device or entity", AREA),
    tool("HassTurnOff", "Turns off, closes or stops a device or entity", AREA),
    tool("HassLightSet", "Sets the brightness or colour of a light",
         {"name": S, "area": S, "floor": S, "brightness": {**I, "minimum": 0, "maximum": 100, "description": "Percent"},
          "color": S, "temperature": {**I, "description": "Colour temperature in kelvin"}}),
    tool("HassClimateSetTemperature", "Sets the target temperature of a climate device or entity",
         {"name": S, "area": S, "floor": S, "temperature": {"type": "number"}}, ["temperature"]),
    tool("GetLiveContext", "Gives the current state, value or mode of devices, sensors and areas. Use it to "
         "answer questions about the home.", {}),
]


def find_tools(data, depth=0):
    """The list of tools in a dumped request, wherever it is."""
    if isinstance(data, list):
        if data and all(isinstance(t, dict) and ("function" in t or "name" in t or "type" in t) for t in data):
            return data
        items = data
    elif isinstance(data, dict):
        for key in ("tools", "functions"):
            if isinstance(data.get(key), list):
                return data[key]
        items = data.values()
    else:
        return None
    if depth < 4:
        for v in items:
            found = find_tools(v, depth + 1) if isinstance(v, (dict, list)) else None
            if found:
                return found
    return None


def convert_tool(t):
    """A function tool in chat-completions format, from that format, the
    Responses API's or Anthropic's. None for anything that isn't a function."""
    if not isinstance(t, dict) or t.get("type", "function") != "function":
        return None
    fn = t["function"] if isinstance(t.get("function"), dict) else t
    name = fn.get("name")
    if not isinstance(name, str) or not name:
        return None
    out = {"name": name}
    if fn.get("description"):
        out["description"] = fn["description"]
    out["parameters"] = fn.get("parameters") or fn.get("input_schema") or {"type": "object", "properties": {}}
    return {"type": "function", "function": out}


def load_tools(path):
    try:
        data = json.loads(pathlib.Path(path).read_text())
    except (OSError, ValueError) as err:
        sys.exit(f"{path}: {err}")
    found = find_tools(data)
    if not found:
        sys.exit(f"{path}: no list of tools in it")
    tools, skipped, names = [], [], set()
    for t in found:
        converted = convert_tool(t)
        if converted is None:
            skipped.append(str(t.get("type") or t.get("name") or "?") if isinstance(t, dict) else "?")
        elif converted["function"]["name"] in names:
            skipped.append(f"a second {converted['function']['name']}")
        else:
            names.add(converted["function"]["name"])
            tools.append(converted)
    if not tools:
        sys.exit(f"{path}: none of its {len(found)} tools is a function")
    return tools, skipped


# Signs of a tool call the server didn't parse, left in the answer's text:
# gpt-oss's harmony tokens, Hermes/Qwen and Mistral tags, Gemma 4's call
# tokens, Gemma 3's and Llama's plain JSON calls.
LEAKED_CALL = re.compile(r"<\|(channel|call|constrain|start|message)\|>|to=functions\.|</?tool_call>|\[TOOL_CALLS\]"
                         r"|<\|tool_call>|<tool_call\|>"
                         r"|<function[=>]|```tool_code|^\s*\{\s*\"(name|function)\"\s*:", re.M)


def leaked_call(content, tools):
    if LEAKED_CALL.search(content):
        return True
    return any(re.search(r"\"name\"\s*:\s*\"" + re.escape(name) + "\"", content) for name in tools)


def check_call(call, tools):
    """Why a tool call isn't valid (None when it is), and its arguments."""
    raw = call["arguments"]
    if not isinstance(raw, str):
        return "its arguments aren't a JSON string", None
    try:
        args = json.loads(raw)
    except ValueError:
        return "its arguments aren't JSON", None
    if not isinstance(args, dict):
        return "its arguments aren't a JSON object", None
    if call["name"] not in tools:
        return f"there's no tool called {call['name']!r}", args
    required = (tools[call["name"]].get("parameters") or {}).get("required") or []
    missing = [r for r in required if r not in args]
    if missing:
        return f"{call['name']} is missing {', '.join(missing)}", args
    return None, args


# -- the agent's tasks -----------------------------------------------------------

AGENT_SYSTEM = """{tag}
You are the researcher, an agent on a small homelab's agent platform. You work \
through the tools you're given: call one whenever you need to look something up, \
run something or remember something, and wait for its result. Don't guess what a \
tool would return. When the task is done, answer in a few sentences without \
calling a tool.

Memory:
- The homelab runs NixOS; its hosts are managed from one flake.
- The operator prefers short answers with the commands to run."""

DF = ("Filesystem      Size  Used Avail Use% Mounted on\n"
      "/dev/vda2       295G  262G   33G  89% /\n"
      "/dev/vda1       511M   61M  451M  12% /boot\n")

TASKS = [
    {"id": "build",
     "prompt": "The inference host's notes are in /srv/notes/inference.md. Find which llama.cpp build they say "
               "the server runs, look up on the web when that build was released, and save a one-line memory "
               "about it. Then tell me the build and its release date.",
     "files": {"/srv/notes/inference.md": "# Inference host\n\nServer: llama.cpp build b9608 (CUDA, sm_86)\n"
                                          "Alias: local\nSlots: 4 x 64K\n"},
     "web": "llama.cpp b9608 was released on 21 October 2026. It fixes streamed tool-call arguments in llama-server.",
     "expect": [r"b9608", r"\b21(st)?\s+oct|oct\w*\s+21|2026-10-21"]},
    {"id": "disk",
     "prompt": "Check how full the root filesystem on this machine is with a terminal command, then read "
               "/srv/notes/disk-policy.md and tell me whether we're over the policy's limit. Save a memory only "
               "if we are.",
     "files": {"/srv/notes/disk-policy.md": "# Disk policy\n\nTell a human when any filesystem is more than 85% full.\n"},
     "web": "Most monitoring guides suggest alerting somewhere between 80% and 90% disk use.",
     "expect": [r"\b89", r"over|above|exceed|more than"]},
    {"id": "port",
     "prompt": "Search the web for the default port of the Wyoming Whisper speech-to-text server, check it "
               "against /etc/wyoming/whisper.conf on this machine, and tell me which port it's set to use.",
     "files": {"/etc/wyoming/whisper.conf": "uri=tcp://0.0.0.0:10300\nmodel=medium-int8\nlanguage=en\n"},
     "web": "wyoming-faster-whisper listens on tcp://0.0.0.0:10300 unless --uri says otherwise.",
     "expect": [r"10300"]},
]


def tool_kind(name):
    n = (name or "").lower()
    if "memory" in n:
        return "memory"
    if any(w in n for w in ("extract", "fetch", "browse", "crawl")):
        return "page"
    if "search" in n:
        return "find" if "file" in n else "web"
    if "read" in n or n in ("cat", "view_file", "open_file"):
        return "read"
    if any(w in n for w in ("terminal", "shell", "bash", "exec", "command", "run")):
        return "shell"
    return "other"


def scripted(task, name, args):
    """What the tool says, from the task's script."""
    kind = tool_kind(name)
    strings = [v for v in args.values() if isinstance(v, str)] if isinstance(args, dict) else []
    if kind == "memory":
        return {"success": True, "message": "Saved to memory."}
    if kind == "web":
        return {"results": [{"title": "Result", "url": "https://example.org/result", "snippet": task["web"]}]}
    if kind == "page":
        return {"content": task["web"]}
    if kind == "find":
        return {"matches": list(task["files"])}
    if kind in ("read", "shell"):
        for path, content in task["files"].items():
            if any(path in s for s in strings):
                return {"content": content} if kind == "read" else {"output": content, "exit_code": 0}
        if kind == "read":
            return {"error": f"File not found: {strings[0] if strings else '(no path given)'}"}
        if any(re.search(r"\bdf\b", s) for s in strings):
            return {"output": DF, "exit_code": 0}
        return {"output": "", "exit_code": 0}
    return {"success": True}


# -- Hermes' on-demand tools ---------------------------------------------------------
#
# Hermes sends only a few tools and keeps the rest behind a bridge: tool_search
# finds them by keyword, tool_describe gives their schemas, and tool_call runs
# one. A dump with the bridge in it gets the tasks below, which need the
# researcher's real tools (Paperclip's and session_search), and the bridge's
# answers are shaped like Hermes' own (tools/tool_search.py in hermes-agent).

SEARCH_NAMES = ("tool_search", "hermes_tool_search")
PAPERCLIP = "mcp__paperclip__paperclip"
ISSUE_ID = {**S, "description": "The issue's UUID or identifier, such as LAB-12"}

# Schemas for the tools the tasks need; the rest of the catalog gets an empty one.
DEFERRED = {
    PAPERCLIP + "GetIssue": ("Get a single issue by UUID or identifier", {"issueId": ISSUE_ID}, ["issueId"]),
    PAPERCLIP + "ListComments": ("List issue comments with incremental options",
                                 {"issueId": ISSUE_ID, "after": {**S, "description": "Only comments after this id"},
                                  "limit": I}, ["issueId"]),
    PAPERCLIP + "AddComment": ("Add a comment to an issue",
                               {"issueId": ISSUE_ID, "body": {**S, "description": "The comment, in markdown"}},
                               ["issueId", "body"]),
    PAPERCLIP + "UpdateIssue": ("Patch an issue, optionally including a comment",
                                {"issueId": ISSUE_ID,
                                 "status": {**S, "enum": ["backlog", "todo", "in_progress", "in_review", "blocked",
                                                          "done", "cancelled"]},
                                 "priority": {**S, "enum": ["low", "medium", "high", "urgent"]},
                                 "comment": {**S, "description": "A comment to add with the change"}}, ["issueId"]),
    PAPERCLIP + "InboxLite": ("Get the current authenticated agent inbox-lite assignment list", {}, []),
    "session_search": ("Recall past conversations: search or read old Hermes sessions",
                       {"query": {**S, "description": "Keywords to look for"}, "limit": I}, ["query"]),
}

ISSUES = {
    "LAB-31": {"title": "Which port does Whisper listen on?", "status": "todo", "priority": "medium",
               "description": "Home Assistant needs the speech-to-text address on the inference host. Which port "
                              "does its Wyoming Whisper server listen on? I pasted its config in a comment.",
               "comments": [{"author": "Justin", "body": "From the host:\n\n```\nuri=tcp://0.0.0.0:10300\n"
                                                        "model=distil-large-v3\nlanguage=en\n```"}]},
    "LAB-32": {"title": "When do the nightly backups start?", "status": "todo", "priority": "low",
               "description": "Someone asked what time the nightly backups start. We settled it in an earlier "
                              "conversation; reply here with the time.", "comments": []},
    "LAB-33": {"title": "Tidy the readme's host list", "status": "todo", "priority": "low",
               "description": "Two retired hosts are still listed.", "comments": []},
    "LAB-34": {"title": "Check the dashboard tiles after the rebuild", "status": "todo", "priority": "medium",
               "description": "A few tiles may point at old addresses.", "comments": []},
    "LAB-35": {"title": "Backups failing on nas-disk-2", "status": "todo", "priority": "urgent",
               "description": "The last three nightly runs failed with I/O errors.", "comments": []},
}
PAST_SESSION = ("Justin: can we move the backups earlier? Researcher: done, the nightly backups now start at "
                "02:30, so they finish before the 03:30 upgrade window.")

BRIDGE_TASKS = [
    {"id": "answer",
     "prompt": "You're assigned LAB-31 in Paperclip. Read it and its comments, answer its question in a comment "
               "on the issue, and mark it done. Then tell me what you answered.",
     "expect": [r"10300"], "comment": ("LAB-31", r"10300"), "status": ("LAB-31", "done")},
    {"id": "recall",
     "prompt": "You're assigned LAB-32 in Paperclip. Read it, find the answer in your past sessions, and reply "
               "with it in a comment on the issue. Leave its status as it is. Then tell me the time.",
     "expect": [r"\b0?2:30\b"], "comment": ("LAB-32", r"\b0?2:30\b"), "status": ("LAB-32", None)},
    {"id": "inbox",
     "prompt": "Check your Paperclip inbox and tell me which of your issues is the most urgent, with its "
               "identifier. Don't change anything.",
     "expect": [r"LAB-35"], "no_writes": True},
]

BRIDGE_SYSTEM = """{tag}
You are the researcher, an agent on a small homelab's agent platform. Your work \
comes as issues in Paperclip, the platform's tracker, and you reach it through \
your tools. Call one whenever you need to look something up or change something, \
and wait for its result. Don't guess what a tool would return. When the task is \
done, answer in a few sentences without calling a tool.

Memory:
- The homelab runs NixOS; its hosts are managed from one flake.
- The operator prefers short answers."""


def tokens(s):
    """Search tokens: lower case, camelCase and snake_case split, a plural s dropped."""
    s = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", s or "")
    return [w[:-1] if len(w) > 3 and w.endswith("s") else w for w in re.findall(r"[a-z0-9]+", s.lower())]


def words(s):
    return set(tokens(s))


def bridge_of(tools):
    """The bridge's search tool's name, when these tools are Hermes' bridge."""
    names = {t["function"]["name"] for t in tools}
    search = next((n for n in SEARCH_NAMES if n in names), None)
    return search if search and {"tool_describe", "tool_call"} <= names else None


def deferred_catalog(search_tool):
    """Name -> description of the tools the search tool's description lists."""
    return dict(re.findall(r"(?m)^- ([A-Za-z0-9_.-]+): (.*)$", search_tool["function"].get("description") or ""))


WRITES = ("Add", "Create", "Update", "Upsert", "Link", "Request", "Ask")
# tool_call's description says to batch independent calls, but Hermes only
# batches connector tools and turns a batch of local ones away. The call is
# well formed, so it isn't counted invalid, only noted: it costs a turn.
BATCHED = "a batch of local tools in one tool_call, which Hermes turns away"


class Bridge:
    """Hermes' side of the on-demand tools, and the issues behind them, for one conversation."""

    def __init__(self, search_name, listed):
        self.search_name = search_name
        self.tools = {n: {"description": d, "parameters": {"type": "object", "properties": {}}}
                      for n, d in listed.items()}
        for name, (desc, props, required) in DEFERRED.items():
            self.tools[name] = {"description": desc,
                                "parameters": {"type": "object", "properties": props, "required": required}}
        self.issues = json.loads(json.dumps(ISSUES))
        self.writes = []

    def handle(self, name, args):
        """The tool's result, and why the call was invalid (None when it wasn't)."""
        if name == self.search_name:
            return self.search(args)
        if name == "tool_describe":
            return self.describe(args)
        if name == "tool_call":
            return self.call(args)
        if "memory" in name:
            return {"success": True, "message": "Saved to memory."}, None
        return {"success": True}, None

    @staticmethod
    def strings(args, key):
        raw = args.get(key)
        raw = [raw] if isinstance(raw, str) else raw
        return [str(x).strip() for x in raw if str(x).strip()] if isinstance(raw, list) else []

    def search(self, args):
        queries = self.strings(args, "queries")
        if not queries:
            return {"error": "queries is required and must be an array of strings"}, "tool_search without queries"
        limit = args.get("limit") if isinstance(args.get("limit"), int) else 5
        limit = max(1, min(limit, 25))
        docs = {n: collections.Counter(tokens(n + " " + t["description"])) for n, t in self.tools.items()}
        results, found = [], {}
        for q in queries:
            known = [w for w in words(q) if any(w in d for d in docs.values())]
            if not known:
                results.append({"query": q, "matches": [], "hint": "No lexical matches. Retry with the service name "
                                                                   "plus a concrete action or object."})
                continue
            # Like Hermes: a match has to carry the query's rarest word, and
            # ranks by BM25.
            freq = {w: sum(w in d for d in docs.values()) for w in known}
            gate = min(known, key=lambda w: freq[w])
            mean = sum(sum(d.values()) for d in docs.values()) / len(docs)

            def score(n):
                d, size = docs[n], sum(docs[n].values())
                return sum(math.log(1 + (len(docs) - freq[w] + 0.5) / (freq[w] + 0.5))
                           * d[w] * 2.2 / (d[w] + 1.2 * (0.25 + 0.75 * size / mean)) for w in known if w in d)
            hits = sorted((n for n, d in docs.items() if gate in d or n.lower() == q.lower()),
                          key=lambda n: (n.lower() != q.lower(), -score(n), n))[:limit]
            results.append({"query": q, "matches": hits})
            for n in hits:
                found[n] = {"source": "mcp" if n.startswith("mcp__") else "builtin",
                            "source_name": n.split("__")[1] if n.startswith("mcp__") else n,
                            "description": self.tools[n]["description"][:500],
                            "required": self.tools[n]["parameters"].get("required", [])}
        return {"queries": queries, "total_available": len(self.tools), "results": results, "tools": found}, None

    def describe(self, args):
        names = self.strings(args, "names")
        if not names:
            return {"error": "names is required and must be an array of strings"}, "tool_describe without names"
        out = {"tools": {n: self.tools[n] for n in dict.fromkeys(names) if n in self.tools}}
        missing = [n for n in dict.fromkeys(names) if n not in self.tools]
        if missing:
            out["not_found"] = missing
            out["hint"] = "Names in not_found are not currently available. Re-run tool_search to refresh."
        return out, None

    def call(self, args):
        calls = args.get("calls")
        calls = [calls] if isinstance(calls, dict) else calls
        if not isinstance(calls, list) or not calls:
            return {"error": "calls is required: an array of {name, arguments}"}, "tool_call without calls"
        if len(calls) > 1:
            first = calls[0] if isinstance(calls[0], dict) else {}
            retry = json.dumps({"calls": [{"name": first.get("name"), "arguments": first.get("arguments", {})}]})
            return ({"error": f"tool_call takes exactly one entry for local tools; you sent {len(calls)}. Retry "
                              f"with only: {retry} then issue the remaining {len(calls) - 1} call(s) as separate "
                              "tool_call invocations."}, BATCHED)
        entry = calls[0]
        name = entry.get("name") if isinstance(entry, dict) else None
        if not isinstance(name, str):
            return {"error": "each call needs a name and arguments"}, "tool_call without a tool name"
        inner = entry.get("arguments", {})
        if isinstance(inner, str):
            try:
                inner = json.loads(inner)
            except ValueError:
                return {"error": f"the arguments for {name} aren't JSON"}, "tool_call arguments that aren't JSON"
        if not isinstance(inner, dict):
            return {"error": f"the arguments for {name} must be an object"}, "tool_call arguments that aren't an object"
        if name not in self.tools:
            return ({"error": f"there's no tool called {name!r}; use tool_search to find one"},
                    f"tool_call of {name!r}, which doesn't exist")
        params = self.tools[name]["parameters"]
        short = name.removeprefix(PAPERCLIP)
        missing = [r for r in params.get("required", []) if r not in inner]
        if missing:
            return (self.invalid(f"tool_call to '{name}' is missing required argument(s): {', '.join(missing)}. "
                                 "The tool was NOT invoked.", "arguments", "required", params),
                    f"tool_call: {short} is missing {', '.join(missing)}")
        for key, value in inner.items():
            why = self.wrong_type(params.get("properties", {}).get(key), value)
            if why:
                return (self.invalid(f"tool_call to '{name}' failed argument validation at arguments.{key} "
                                     f"({why[0]}): {why[1]}. The tool was NOT invoked.",
                                     f"arguments.{key}", why[0], params),
                        f"tool_call: {short}'s {key} {why[1]}")
        return self.run(name, inner), None

    @staticmethod
    def invalid(message, path, constraint, params):
        """Hermes' answer to a call that doesn't fit the schema: the schema itself, to retry with."""
        return {"error": message, "path": path, "constraint": constraint, "parameters": params,
                "hint": "Retry tool_call with 'arguments' matching the parameters schema above."}

    @staticmethod
    def wrong_type(prop, value):
        """(constraint, why) when value doesn't fit prop, after Hermes' coercion of numbers in strings."""
        if not isinstance(prop, dict):
            return None
        kind = prop.get("type")
        ok = {"string": isinstance(value, str),
              "integer": (isinstance(value, int) and not isinstance(value, bool))
                         or (isinstance(value, str) and value.strip().lstrip("-").isdigit()),
              "boolean": isinstance(value, bool) or str(value).lower() in ("true", "false"),
              "array": isinstance(value, list), "object": isinstance(value, dict)}.get(kind, True)
        if not ok:
            return "type", f"is not of type '{kind}'"
        if "enum" in prop and value not in prop["enum"]:
            return "enum", f"{json.dumps(value)} is not one of {prop['enum']}"
        return None

    def issue(self, ref):
        ref = str(ref or "").strip().upper()
        return next(((k, v) for k, v in self.issues.items() if k == ref), (None, None))

    def run(self, name, a):
        short = name.removeprefix(PAPERCLIP)
        if name == "session_search":
            hit = words(str(a.get("query"))) & {"backup", "nightly", "schedule", "time", "start"}
            return {"results": [{"session_id": "20261028_201455_4f2a", "when": "2026-10-28",
                                 "snippet": PAST_SESSION}] if hit else []}
        if short == "InboxLite":
            return {"issues": [{"identifier": k, "title": v["title"], "status": v["status"],
                                "priority": v["priority"]} for k, v in self.issues.items()]}
        if short.startswith(WRITES) and name.startswith(PAPERCLIP):
            self.writes.append((str(a.get("issueId", "")).upper(), short, json.dumps(a)))
        if short in ("GetIssue", "ListComments", "AddComment", "UpdateIssue"):
            key, it = self.issue(a.get("issueId"))
            if key is None:
                return {"error": f"Issue not found: {a.get('issueId')}"}
            if short == "GetIssue":
                return {"identifier": key, **{k: v for k, v in it.items() if k != "comments"},
                        "assignee": "researcher", "commentCount": len(it["comments"])}
            if short == "ListComments":
                return {"comments": it["comments"]}
            body = a.get("body") if short == "AddComment" else a.get("comment")
            if body:
                it["comments"].append({"author": "researcher", "body": body})
                self.writes.append((key, "comment", body))
            for field in ("status", "priority"):
                if short == "UpdateIssue" and field in a:
                    it[field] = a[field]
                    self.writes.append((key, field, a[field]))
            return {"ok": True, "identifier": key, "status": it["status"]}
        return {"ok": True, "result": []}

    def right(self, task, answer):
        """The answer has what it should, and the issues were changed as asked and no more."""
        if not all(re.search(p, fold(answer), re.I) for p in task["expect"]):
            return False
        if task.get("no_writes"):
            return not self.writes
        key, pattern = task["comment"]
        if not any(k == key and what == "comment" and re.search(pattern, fold(v)) for k, what, v in self.writes):
            return False
        key, want = task["status"]
        set_to = [v for k, what, v in self.writes if k == key and what == "status"]
        return not set_to if want is None else bool(set_to) and set_to[-1] == want


# -- the other prompts -------------------------------------------------------------

FILLER = (
    ["The keeper", "A fishing boat", "The relief crew", "The supply ferry", "A gull", "The north lamp",
     "The radio", "The tide", "A visiting surveyor", "The foghorn", "The cook", "The new apprentice"],
    ["checked", "passed", "repaired", "logged", "circled", "lit", "reported", "reached", "measured", "tested",
     "painted", "ignored"],
    ["the lower gallery", "the harbour wall", "the spare lens", "the eastern reef", "the rain barrel",
     "the signal mast", "the coal store", "the landing stage", "the weather log", "the spiral stair",
     "the old boathouse", "the brass clock"],
    ["before dawn", "in a steady drizzle", "for the third time that week", "while the kettle boiled",
     "as the wind backed west", "just after noon", "without much trouble", "under a clear sky", "at low water",
     "late in the evening", "after a long argument", "with some care"],
)


def filler(chars, seed):
    """Synthetic prose, about chars long."""
    rng = random.Random(seed)
    out, n, k = [], 0, 0
    while n < chars:
        s = " ".join(rng.choice(part) for part in FILLER) + "."
        k += 1
        if k % 8 == 0:
            s += "\n\n"
        out.append(s)
        n += len(s) + 1
    return " ".join(out)[:chars]


THREAD_LINES = [
    "The compost bays by the gate need turning again; the fork is in the shed if anyone has a free hour.",
    "Has anyone seen the long-handled loppers? They weren't on their hook this morning.",
    "The seed swap table will be in the hut as usual, so bring envelopes and labels.",
    "Plot 12's broad beans came through the frost better than I expected.",
    "Please don't park across the farm gate on Elm Road; the farmer has asked twice now.",
    "The rain gauge read 31 mm over the weekend, so nobody needs to water this week.",
    "There are spare rhubarb crowns in a bucket by the hut if anyone wants them.",
    "I'll bring the urn for tea, but we're short of mugs, so bring your own if you can.",
    "The rota for opening the gate on Sundays is pinned inside the hut door.",
    "Someone left the hose running near plot 4 on Tuesday and the meter took a jump.",
    "Thanks to everyone who came to the pruning session; the apple trees look much better.",
    "Slugs are bad again on the lower plots, and beer traps seem to be working for some of us.",
    "The wheelbarrow with the flat tyre is fixed and back by the compost.",
    "The newsletter goes out at the end of the month, so send me anything you want in it.",
    "The netting over the fruit cage has a tear on the north side.",
    "The green waste skip is booked for the first week of April.",
    "Can we talk about the shared tool budget at the next meeting?",
    "Whoever borrowed the soil tester, could you put it back in the cupboard?",
]
THREAD_PEOPLE = ["Priya Raman", "Tom Okafor", "Marguerite Hale", "Dev Patel", "Ines Moreau", "Callum Reid", "Joy Lindqvist"]
# What the thread is about, at the positions they come in. The rest is chatter.
THREAD_KEY = {
    0: ("Priya Raman", "Hi all,\n\nThe spring work day is Saturday 7 March from 9am. The big job is replacing the "
                       "water tank behind the shed, which has leaked since January. Tom is getting quotes."),
    9: ("Tom Okafor", "Two quotes are in. Brookfield Tanks: $1,240 for a 1,000 litre tank, delivered and installed. "
                      "Harlow Supplies: $980 for the same size, but we'd fit it ourselves and hire a pump."),
    20: ("Marguerite Hale", "The committee met last night and agreed on Brookfield at $1,240, since it includes "
                            "installation. I've paid the deposit from the maintenance fund."),
    33: ("Priya Raman", "Change of plan: Brookfield can only deliver on the 14th, so the work day moves to "
                        "Saturday 14 March, same time, 9am. Please update your calendars."),
    45: ("Dev Patel", "Sam, could you bring your trailer on the day to take the old tank to the tip? "
                      "Can you confirm by Thursday?"),
}
SUMMARY_FACTS = {
    "the new date": r"\b14(th)?\s+(of\s+)?march\b|\bmarch\s+14(th)?\b|\bthe\s+14th\b|\b14/0?3\b",
    "the $1,240 quote": r"1[, ]?240",
    "the trailer": r"\btrailer\b",
}


def make_thread(seed, messages=56):
    rng = random.Random(seed)
    when = datetime.datetime(2026, 2, 16, 8, 30)
    out, previous = [], None
    for i in range(messages):
        if i in THREAD_KEY:
            who, body = THREAD_KEY[i]
        else:
            who = rng.choice(THREAD_PEOPLE)
            body = " ".join(rng.sample(THREAD_LINES, rng.randint(2, 5)))
        sign = who.split()[0]
        quoted = ""
        if previous:
            quoted = "\n\n" + "\n".join("> " + line for line in previous.splitlines())
        subject = "Spring work day" if i == 0 else "Re: Spring work day"
        out.append(f"From: {who}\nDate: {when:%a %d %b %Y %H:%M}\nSubject: {subject}\n\n{body}\n\n{sign}{quoted}")
        previous = f"{body}\n\n{sign}"
        when += datetime.timedelta(minutes=rng.randint(30, 420))
    return "\n\n--------\n\n".join(out)


TRIAGE = [
    {"alerts": [
        ("A1", "SVC / gitea", "http", "resolved", "down for 40 s at 02:13, up since 02:14"),
        ("A2", "backup / nas-disk-2", "disk", "firing", "/mnt/backup is 97% full and growing 2% a day; SMART "
                                                         "reallocated sectors went from 8 to 64 since Monday"),
        ("A3", "cert / paperclip", "tls", "firing", "certificate expires in 24 days; the renewal timer is scheduled"),
    ], "needs_human": True, "urgent": "A2"},
    {"alerts": [
        ("B1", "SVC / homarr", "http", "resolved", "down for 30 s at 04:02 during the nightly restart, up since"),
        ("B2", "cert / gitea", "tls", "firing", "certificate expires in 27 days; the renewal timer is scheduled"),
        ("B3", "host / agents", "cpu", "resolved", "CPU at 92% for 3 minutes during the 03:00 backup, 18% now"),
    ], "needs_human": False, "urgent": None},
]

MEMORY_NOW = ["The homelab runs NixOS; its hosts are managed from one flake.",
              "The operator prefers short answers with the commands to run."]
MEMORY_CASES = [
    {"id": "preference", "write": True, "mention": r"draft", "conversation": [
        ("operator", "Can you open the pull request for the Homarr tile change?"),
        ("agent", "Opened it. It moves the tile's ping to /health."),
        ("operator", "Thanks. From now on, open pull requests as drafts, please. I review them on my phone in the "
                     "evening and mark them ready myself."),
        ("agent", "Understood, I'll open them as drafts.")]},
    {"id": "one-off", "write": False, "conversation": [
        ("operator", "How many millilitres are in three US cups?"),
        ("agent", "About 710 ml."),
        ("operator", "Great, thanks.")]},
    {"id": "known", "write": False, "conversation": [
        ("operator", "Remind me, what do the lab hosts run?"),
        ("agent", "NixOS, all managed from the one flake."),
        ("operator", "Right, NixOS, of course.")]},
]

HA_SYSTEM = """{tag}
You are a voice assistant for Home Assistant.
Answer questions about the world truthfully.
Answer in plain text. Keep it short and to the point.
To control the home, call the intent tools. For a device, prefer passing just its \
name and domain; for an area, just the area's name and the domain.
Use GetLiveContext to answer questions about the current state of the home.
An overview of the areas and the devices in this home:
- names: Kitchen Lights
  domain: light
  areas: Kitchen
- names: Bedroom Lamp
  domain: light
  areas: Bedroom
- names: Hall Light
  domain: light
  areas: Hall
- names: Living Room Thermostat
  domain: climate
  areas: Living Room
- names: Front Door
  domain: lock
  areas: Hall
- names: TV
  domain: media_player
  areas: Living Room"""

VOICE = [
    {"say": "Turn on the kitchen lights.", "tool": "HassTurnOn", "key": None, "value": "kitchen"},
    {"say": "Set the living room to 21 degrees.", "tool": "HassClimateSetTemperature", "key": "temperature", "value": 21},
    {"say": "Dim the bedroom lamp to 30 percent.", "tool": "HassLightSet", "key": "brightness", "value": 30},
]

REASONING_PROMPT = ("A train leaves at 14:10 and reaches the coast at 16:45. On the way it stops twice, for 12 "
                    "minutes each time. For how many minutes is it moving? Answer with the number only.")
REASONING_ANSWER = r"\b131\b"


def structured(content):
    """The JSON object in an answer, and whether the answer was only that
    ("clean") or it had to be cut out of fences or prose ("wrapped")."""
    s = re.sub(r"(?s)<think>.*?</think>", "", content).strip()
    obj = parse_json(s)
    if isinstance(obj, dict):
        return obj, "clean"
    for candidate in re.findall(r"(?s)```(?:json)?\s*(\{.*?\})\s*```", s) + [s[s.find("{"): s.rfind("}") + 1]]:
        obj = parse_json(candidate)
        if isinstance(obj, dict):
            return obj, "wrapped"
    return None, None


def matches(value, want):
    """Whether a tool argument says what the command asked for."""
    if isinstance(want, str):
        found = value if isinstance(value, list) else [value]
        return any(isinstance(v, str) and want in v.lower() for v in found)
    try:
        return float(value) == float(want)
    except (TypeError, ValueError):
        return False


def think_length(answer):
    """Reasoning the server split off, plus any left in the text: Qwen's
    <think> or Gemma 4's thought channel."""
    found = re.findall(r"(?s)<think>(.*?)</think>|<\|channel>thought(.*?)<channel\|>", answer["content"])
    inline = sum(len(qwen) + len(gemma) for qwen, gemma in found)
    return len(answer["reasoning"]) + inline


def changed(base, other):
    """Whether a variant's median differs enough from the default's to count."""
    if base is None or other is None:
        return None
    if (base == 0) != (other == 0):
        return True
    if base == 0:
        return False
    return not 2 / 3 <= other / base <= 1.5


# -- the test ----------------------------------------------------------------------

class Tester:
    def __init__(self, client, args):
        self.client = client
        self.args = args
        self.canary = f"canary-{secrets.token_hex(8)}"
        self.tokens_per_char = FALLBACK_TOKENS_PER_CHAR
        self.calibration = {}
        if args.tools:
            self.agent_tools, skipped = load_tools(args.tools)
            say(f"tools: {len(self.agent_tools)} function tools from {args.tools}"
                + (f", skipped {len(skipped)} that aren't: {', '.join(skipped)}" if skipped else ""))
        else:
            self.agent_tools = AGENT_TOOLS
        self.bridge = bridge_of(self.agent_tools)
        self.catalog = {}
        if self.bridge:
            search = next(t for t in self.agent_tools if t["function"]["name"] == self.bridge)
            self.catalog = deferred_catalog(search)
            if self.bridge != "tool_search":
                # Codex's name for it. Over chat completions, as with the local
                # model, Hermes calls it tool_search.
                self.agent_tools = [{"type": "function", "function": {**t["function"], "name": "tool_search"}}
                                    if t is search else t for t in self.agent_tools]
                self.bridge = "tool_search"
            say(f"tools: Hermes' on-demand bridge, with {len(self.catalog)} tools behind it; "
                "the agent tasks are Paperclip issues")
        if args.ha_tools:
            self.ha_tools, skipped = load_tools(args.ha_tools)
            say(f"ha tools: {len(self.ha_tools)} function tools from {args.ha_tools}"
                + (f", skipped {len(skipped)} that aren't: {', '.join(skipped)}" if skipped else ""))
        else:
            self.ha_tools = HA_TOOLS

    def tag(self, nonce=True):
        """Starts every prompt: the run's canary, and a nonce so no prompt shares
        a prefix the server could have cached from another."""
        return f"[test {self.canary} {secrets.token_hex(4)}]" if nonce else f"[test {self.canary}]"

    def chars_for(self, tokens):
        return int(tokens / self.tokens_per_char)

    def calibrate(self):
        """Tokens per character of filler, from two prompts that differ only by it."""
        ask = f"{self.tag()} Reply with OK."
        body = filler(16000, 0)
        try:
            small = self.client.chat({"messages": [{"role": "user", "content": ask}], "max_tokens": 1})
            big = self.client.chat({"messages": [{"role": "user", "content": f"{ask}\n\n{body}"}], "max_tokens": 1})
        except Fail as err:
            if err.status in (401, 403):
                raise
            self.calibration = {"error": str(err)}
            say(f"couldn't calibrate, so it guesses {FALLBACK_TOKENS_PER_CHAR} tokens per character: {err}")
            return
        a = (small["usage"].get("prompt_tokens") or small["timings"].get("prompt_n"))
        b = (big["usage"].get("prompt_tokens") or big["timings"].get("prompt_n"))
        if a and b and b > a:
            self.tokens_per_char = (b - a) / (len(body) + 2)
            self.calibration = {"tokens_per_char": round(self.tokens_per_char, 4), "small": a, "big": b}
            say(f"filler is {self.tokens_per_char:.3f} tokens per character")
        else:
            self.calibration = {"error": "no prompt token counts in the answers"}
            say(f"no prompt token counts, so it guesses {FALLBACK_TOKENS_PER_CHAR} tokens per character")

    # -- tools ---------------------------------------------------------------------

    def tools(self):
        names = {t["function"]["name"]: t["function"] for t in self.agent_tools}
        tasks = BRIDGE_TASKS if self.bridge else TASKS
        runs = [self.agent_run(tasks[i % len(tasks)], names) for i in range(self.args.repeat)]
        calls = [c for r in runs for c in r["calls"]]
        valid = sum(c["valid"] for c in calls)
        loops = sum(1 for r in runs if r["loop"])
        finished = sum(r["finished"] for r in runs)
        correct = sum(r["correct"] for r in runs)
        errors = [r["error"] for r in runs if r["error"]]
        rate = valid / len(calls) if calls else 0.0
        problems = {}
        for c in calls:
            if c["problem"]:
                problems[c["problem"]] = problems.get(c["problem"], 0) + 1
        ok = bool(calls) and rate >= self.args.tool_target and loops == 0 and not errors and correct == len(runs)
        result = (f"{valid}/{len(calls)} valid ({rate:.0%}), {loops} loop(s), {finished}/{len(runs)} finished, "
                  f"{correct} right")
        notes = [f"{n} x {p}" for p, n in sorted(problems.items(), key=lambda kv: -kv[1])] + errors
        if not calls:
            notes.append("the model never called a tool")
        return {"status": "PASS" if ok else "FAIL",
                "target": f">= {self.args.tool_target:.0%} valid, no loops, every run right",
                "result": result, "runs": runs, "notes": notes, "calls": len(calls), "valid": valid,
                "loops": loops, "finished": finished, "correct": correct}

    def agent_run(self, task, names):
        bridge = Bridge(self.bridge, self.catalog) if self.bridge else None
        system = BRIDGE_SYSTEM if bridge else AGENT_SYSTEM
        messages = [{"role": "system", "content": system.format(tag=self.tag())},
                    {"role": "user", "content": task["prompt"]}]
        # A call to a bridged tool left in the text is a leaked call too.
        leak_names = list(names) + (list(bridge.tools) if bridge else [])
        record = {"task": task["id"], "calls": [], "turns": 0, "loop": None, "finished": False,
                  "correct": False, "answer": "", "error": None, "first_token": []}
        seen = []
        for turn in range(self.args.max_turns):
            body = {"messages": messages, "tools": self.agent_tools, "max_tokens": self.args.max_tokens}
            try:
                answer = self.client.stream(body) if self.args.stream_tools else self.client.chat(body)
            except Fail as err:
                record["error"] = str(err)
                break
            record["turns"] += 1
            record["first_token"].append(answer["first_token"])
            if not answer["tool_calls"]:
                record["answer"] = answer["content"]
                record["finish_reason"] = answer["finish_reason"]
                if leaked_call(answer["content"], leak_names):
                    # Hermes would take this for the final answer.
                    record["calls"].append({"name": None, "arguments": text(answer["content"], 300), "valid": False,
                                            "problem": "a tool call left in the answer's text"})
                    break
                record["finished"] = bool(answer["content"].strip()) and answer["finish_reason"] != "length"
                record["correct"] = (bridge.right(task, answer["content"]) if bridge
                                     else all(re.search(p, fold(answer["content"]), re.I) for p in task["expect"]))
                break
            assistant = {"role": "assistant", "content": answer["content"] or None, "tool_calls": []}
            # Handed back like any client that keeps reasoning between tool calls.
            if answer["reasoning"]:
                assistant["reasoning_content"] = answer["reasoning"]
            replies = []
            for n, call in enumerate(answer["tool_calls"]):
                cid = call["id"] or f"call_{turn}_{n}"
                raw = call["arguments"] if isinstance(call["arguments"], str) else json.dumps(call["arguments"])
                assistant["tool_calls"].append({"id": cid, "type": "function",
                                                "function": {"name": call["name"], "arguments": raw}})
                problem, args = check_call(call, names)
                if problem:
                    result = {"error": f"Invalid tool call: {problem}"}
                elif bridge:
                    result, problem = bridge.handle(call["name"], args)
                else:
                    result = scripted(task, call["name"], args)
                batched = problem == BATCHED
                record["calls"].append({"name": call["name"], "arguments": text(raw, 300),
                                        "valid": problem is None or batched, "problem": problem})
                seen.append((call["name"], json.dumps(args, sort_keys=True) if args is not None else raw))
                if len(seen) >= 3 and seen[-1] == seen[-2] == seen[-3] and not record["loop"]:
                    record["loop"] = call["name"]
                replies.append({"role": "tool", "tool_call_id": cid, "content": json.dumps(result)})
            messages.append(assistant)
            messages.extend(replies)
            if record["loop"]:
                break
        if bridge:
            record["writes"] = [{"issue": k, "what": w, "value": text(v, 200)} for k, w, v in bridge.writes]
        bad = [c for c in record["calls"] if not c["valid"]]
        line = f"    {task['id']}: {len(record['calls'])} call(s) in {record['turns']} turn(s)"
        line += f", {len(bad)} invalid" if bad else ", all valid"
        if record["loop"]:
            line += f", looped on {record['loop']}"
        elif record["error"]:
            line += f", stopped: {record['error']}"
        elif bad and bad[-1]["name"] is None:
            line += f", then left a tool call in its answer: {text(record['answer'], 120)}"
        elif record.get("finish_reason") == "length":
            line += f", ran out of tokens (--max-tokens {self.args.max_tokens})"
        elif not record["finished"]:
            line += f", no answer after {self.args.max_turns} turns"
        else:
            line += ", answered " + ("right" if record["correct"] else f"wrongly: {text(record['answer'], 120)}")
        if bridge:
            changed = sorted({f"{k} {w}" for k, w, _ in bridge.writes if w in ("comment", "status", "priority")})
            line += f"; changed {', '.join(changed) if changed else 'nothing'}"
        say(line)
        return record

    # -- answers that are checked ----------------------------------------------------

    def summary(self):
        runs = []
        for i in range(self.args.repeat):
            thread = make_thread(i)
            messages = [
                {"role": "system", "content": f"{self.tag()}\nYou are Sam's email assistant. Sam is on the "
                                              "allotment association's mailing list."},
                {"role": "user", "content": f"Here's an email thread Sam was copied on.\n\n{thread}\n\nWrite a "
                                            "short summary of where things stand, then draft Sam's reply. Use two "
                                            "sections, each starting on its own line with Summary: and then "
                                            "Reply:."}]
            try:
                answer = self.client.chat({"messages": messages, "max_tokens": self.args.max_tokens})
            except Fail as err:
                runs.append({"ok": False, "error": str(err)})
                say(f"    run {i + 1}: {err}")
                continue
            content = re.sub(r"(?s)<think>.*?</think>", "", answer["content"])
            missed = [name for name, p in SUMMARY_FACTS.items() if not re.search(p, fold(content), re.I)]
            if not re.search(r"(?im)^[\s#*_>]*summary\b", content):
                missed.append("a summary section")
            if not re.search(r"(?im)^[\s#*_>]*(reply|draft)\b", content):
                missed.append("a reply section")
            runs.append({"ok": not missed, "missed": missed, "answer": content, "seconds": round(answer["elapsed"], 2),
                         "prompt_tokens": answer["usage"].get("prompt_tokens")})
            say(f"    run {i + 1}: " + ("every fact and a reply" if not missed else "missed " + ", ".join(missed))
                + f" ({secs(answer['elapsed'])}, {answer['usage'].get('prompt_tokens', '?')} prompt tokens)")
        return self.tally(runs, "every fact and a reply", "the date, the price, the trailer, both sections")

    def triage(self):
        runs = []
        for i in range(self.args.repeat):
            case = TRIAGE[i % len(TRIAGE)]
            table = "\n".join(f"{a[0]}  {a[1]}  ({a[2]}, {a[3]}): {a[4]}" for a in case["alerts"])
            messages = [
                {"role": "system", "content": f"{self.tag()}\nYou triage alerts for a homelab. A human is paged only "
                                              "for something that will cause harm or lose data if nobody acts within "
                                              "a day. Resolved alerts and things that fix themselves don't need one."},
                {"role": "user", "content": f"Current alerts:\n{table}\n\nAnswer with only a JSON object and no other "
                                            'text: {"most_urgent": the id of the alert that most needs attention, or '
                                            'null if none does, "needs_human": true or false, "severity": "critical", '
                                            '"warning" or "info", "reason": one sentence}'}]
            run = self.structured_run(i, messages, self.triage_checks(case))
            runs.append(run)
        return self.tally(runs, "structured and right", "JSON with the right call")

    @staticmethod
    def triage_checks(case):
        def check(obj):
            problems = []
            if not isinstance(obj.get("needs_human"), bool):
                problems.append("needs_human isn't true or false")
            elif obj["needs_human"] != case["needs_human"]:
                problems.append(f"needs_human is {str(obj['needs_human']).lower()}")
            if not (obj.get("most_urgent") is None or isinstance(obj.get("most_urgent"), str)):
                problems.append("most_urgent isn't an id or null")
            elif case["urgent"] and obj.get("most_urgent") != case["urgent"]:
                problems.append(f"most_urgent is {obj.get('most_urgent')}, not {case['urgent']}")
            if obj.get("severity") not in ("critical", "warning", "info"):
                problems.append("severity isn't critical, warning or info")
            if not isinstance(obj.get("reason"), str):
                problems.append("no reason")
            return problems
        return check

    def memory(self):
        runs = []
        for i in range(self.args.repeat):
            case = MEMORY_CASES[i % len(MEMORY_CASES)]
            talk = "\n".join(f"{who}: {said}" for who, said in case["conversation"])
            now = "\n".join(f"- {m}" for m in MEMORY_NOW)
            messages = [
                {"role": "system", "content": f"{self.tag()}\nYou review a finished conversation between an agent "
                                              "and its operator, and decide whether anything in it should go into "
                                              "the agent's long-term memory. Save durable things: preferences, "
                                              "corrections, facts about the operator or their setup that will matter "
                                              "in later sessions. Don't save one-off details, anything already in "
                                              "memory, or secrets."},
                {"role": "user", "content": f"Current memory:\n{now}\n\nConversation:\n{talk}\n\nAnswer with only a "
                                            'JSON object and no other text: {"write": true or false, "content": the '
                                            'memory to save, as one sentence, or null, "reason": one sentence}'}]
            runs.append(self.structured_run(i, messages, self.memory_checks(case)))
        return self.tally(runs, "structured and right", "JSON with the right decision")

    @staticmethod
    def memory_checks(case):
        def check(obj):
            problems = []
            write, content = obj.get("write"), obj.get("content")
            if not isinstance(write, bool):
                problems.append("write isn't true or false")
            elif write != case["write"]:
                problems.append(f"write is {str(write).lower()} for the {case['id']} case")
            if write is True and not (isinstance(content, str) and content.strip()):
                problems.append("nothing to write")
            elif write is True and case.get("mention") and not re.search(case["mention"], content, re.I):
                problems.append(f"the memory doesn't mention {case['mention']}")
            if content is not None and not isinstance(content, str):
                problems.append("content isn't text or null")
            if not isinstance(obj.get("reason"), str):
                problems.append("no reason")
            return problems
        return check

    def structured_run(self, i, messages, check):
        try:
            answer = self.client.chat({"messages": messages, "max_tokens": self.args.max_tokens})
        except Fail as err:
            say(f"    run {i + 1}: {err}")
            return {"ok": False, "structured": False, "error": str(err)}
        obj, how = structured(answer["content"])
        problems = ["no JSON object in the answer"] if obj is None else check(obj)
        say(f"    run {i + 1}: " + (f"right ({how} JSON)" if not problems else "; ".join(problems))
            + f" ({secs(answer['elapsed'])})")
        return {"ok": not problems, "structured": obj is not None, "how": how, "missed": problems,
                "answer": answer["content"], "seconds": round(answer["elapsed"], 2)}

    def tally(self, runs, good, target):
        ok = sum(r["ok"] for r in runs)
        notes = sorted({m for r in runs for m in r.get("missed", [])}) + [r["error"] for r in runs if r.get("error")]
        result = f"{ok}/{len(runs)} {good}"
        if any("structured" in r for r in runs):
            result += f", {sum(r.get('structured', False) for r in runs)}/{len(runs)} gave JSON"
        return {"status": "PASS" if runs and ok == len(runs) else "FAIL", "target": target, "result": result,
                "runs": runs, "notes": notes}

    # -- voice -------------------------------------------------------------------------

    def voice(self):
        return self.voice_runs(loaded=False)

    def voice_load(self):
        return self.voice_runs(loaded=True)

    def voice_runs(self, loaded):
        names = {t["function"]["name"]: t["function"] for t in self.ha_tools}
        runs = []
        for i in range(self.args.repeat):
            cmd = VOICE[i % len(VOICE)]
            load = self.start_load(i) if loaded else None
            run = {"say": cmd["say"]}
            try:
                answer = self.client.stream({
                    "messages": [{"role": "system", "content": HA_SYSTEM.format(tag=self.tag(nonce=False))},
                                 {"role": "user", "content": cmd["say"]}],
                    "tools": self.ha_tools, "max_tokens": self.args.voice_tokens})
            except Fail as err:
                run["error"] = str(err)
                answer = None
            if load:
                load["thread"].join(self.args.timeout + 30)
                run["load"] = {k: v for k, v in load.items() if k not in ("thread", "ended")}
            if answer is None:
                say(f"    {cmd['say']!r}: {run['error']}")
                runs.append(run)
                continue
            call = answer["tool_calls"][0] if answer["tool_calls"] else None
            problem, args = check_call(call, names) if call else ("no tool call", None)
            right = None
            if cmd["tool"] in names:
                right = (call is not None and problem is None and call["name"] == cmd["tool"]
                         and (any(matches(v, cmd["value"]) for v in args.values()) if cmd["key"] is None
                              else matches(args.get(cmd["key"]), cmd["value"])))
            run.update(first_token=answer["first_token"], first_any=answer["first_any"], done=answer["elapsed"],
                       retries=answer["retries"], valid=problem is None, problem=problem, right=right,
                       call=None if call is None else {"name": call["name"], "arguments": text(call["arguments"], 200)},
                       content=text(answer["content"], 200))
            if load:
                first_at = answer["started"] + (answer["first_token"] or answer["elapsed"])
                run["overlapped"] = load.get("ended") is not None and load["ended"] > first_at
            line = f"    {cmd['say']!r}: first token {secs(answer['first_token'])}, done {secs(answer['elapsed'])}"
            line += f", {call['name']}" if call else ", no tool call"
            if problem and call:
                line += f" (invalid: {problem})"
            elif right is not None:
                line += " (right)" if right else " (not what was asked)"
            if answer["retries"]:
                line += f", after {answer['retries']} x 429"
            if load:
                line += (", during the long prompt" if run["overlapped"]
                         else ", but the long prompt had finished") + f" ({run['load'].get('summary')})"
            say(line)
            runs.append(run)
        return self.voice_tally(runs, loaded)

    def start_load(self, i):
        """A request with about --load-tokens of prompt, in the background."""
        load = {}
        content = (f"{self.tag()}\nHere are a lighthouse keeper's log notes. Summarise them in one sentence.\n\n"
                   + filler(self.chars_for(self.args.load_tokens), 1000 + i))

        def send():
            try:
                answer = self.client.chat({"messages": [{"role": "user", "content": content}], "max_tokens": 32})
                tokens = answer["usage"].get("prompt_tokens") or answer["timings"].get("prompt_n")
                speed = answer["timings"].get("prompt_per_second")
                load.update(ok=True, prompt_tokens=tokens, seconds=round(answer["elapsed"], 2),
                            prompt_per_second=speed, retries=answer["retries"],
                            summary=f"{tokens or '?'} tokens in {secs(answer['elapsed'])}")
            except Fail as err:
                load.update(ok=False, error=str(err), summary=f"it failed: {err}")
            load["ended"] = time.monotonic()

        load["thread"] = threading.Thread(target=send, daemon=True)
        load["thread"].start()
        time.sleep(self.args.load_delay)
        return load

    def voice_tally(self, runs, loaded):
        target = self.args.voice_load_target if loaded else self.args.voice_target
        firsts = [r.get("first_token") for r in runs]
        errors = [r["error"] for r in runs if r.get("error")]
        notes = errors + sorted({r["problem"] for r in runs if r.get("problem")})
        slowest = biggest(firsts)
        ok = not errors and None not in firsts and slowest is not None and slowest <= target
        if loaded:
            apart = sum(1 for r in runs if not r.get("overlapped"))
            if apart:
                ok = False
                notes.append(f"in {apart} run(s) the long prompt was done before the first token; "
                             "lower --load-delay or raise --load-tokens")
            failed = [r["load"].get("error") for r in runs if r.get("load") and not r["load"].get("ok")]
            notes += [f"the long prompt failed: {e}" for e in failed]
            ok = ok and not failed
        right = [r.get("right") for r in runs if r.get("right") is not None]
        result = f"first token {secs(median(firsts))} median, {secs(slowest)} slowest"
        result += f"; tool call done {secs(median([r.get('done') for r in runs]))} median"
        if right:
            result += f"; {sum(right)}/{len(right)} right"
        return {"status": "PASS" if ok else "FAIL", "target": f"first token <= {target:g} s",
                "result": result, "runs": runs, "notes": notes}

    # -- refusal -------------------------------------------------------------------------

    def refusal(self):
        runs = []
        for i in range(self.args.repeat):
            content = (f"{self.tag()}\nWhat is the last word of these notes?\n\n"
                       + filler(self.chars_for(self.args.over_tokens), 2000 + i))
            try:
                answer = self.client.chat({"messages": [{"role": "user", "content": content}], "max_tokens": 16})
            except Fail as err:
                body = err.body.get("error") if isinstance(err.body, dict) else None
                body = body if isinstance(body, dict) else {}
                message = str(body.get("message") or err)
                about_context = "context" in message.lower() or "context" in str(body.get("type", ""))
                run = {"refused": err.status == 400 and about_context, "status": err.status,
                       "type": body.get("type"), "message": text(message, 200),
                       "n_prompt_tokens": body.get("n_prompt_tokens"), "n_ctx": body.get("n_ctx")}
                if run["refused"]:
                    say(f"    run {i + 1}: refused, HTTP 400 {body.get('type') or ''}"
                        + (f" ({body.get('n_prompt_tokens')} tokens > {body.get('n_ctx')})"
                           if body.get("n_prompt_tokens") else ""))
                else:
                    say(f"    run {i + 1}: failed, but not with a context error: {err}")
                runs.append(run)
                continue
            tokens = answer["usage"].get("prompt_tokens") or answer["timings"].get("prompt_n")
            runs.append({"refused": False, "status": 200, "prompt_tokens": tokens, "answer": text(answer["content"], 200)})
            say(f"    run {i + 1}: answered instead of refusing ({tokens or '?'} prompt tokens counted)")
        refused = sum(r["refused"] for r in runs)
        notes = sorted({f"answered with {r.get('prompt_tokens') or '?'} prompt tokens counted: truncated"
                        for r in runs if r["status"] == 200})
        notes += sorted({f"HTTP {r['status']}: {r['message']}" for r in runs if r["status"] != 200 and not r["refused"]})
        return {"status": "PASS" if runs and refused == len(runs) else "FAIL",
                "target": f"HTTP 400 over {CONTEXT_PER_SLOT} tokens",
                "result": f"{refused}/{len(runs)} refused, at about {self.args.over_tokens} tokens",
                "runs": runs, "notes": notes}

    # -- reasoning ---------------------------------------------------------------------------

    def reasoning(self):
        kwargs = (json.loads(self.args.reasoning_kwargs) if self.args.reasoning_kwargs
                  else {"reasoning_effort": self.args.reasoning_effort, "enable_thinking": True})
        variants = [("default", {}), ("chat_template_kwargs", {"chat_template_kwargs": kwargs}),
                    ("reasoning_effort", {"reasoning_effort": self.args.reasoning_effort})]
        runs, medians, errors = {}, {}, []
        for name, extra in variants:
            runs[name] = []
            for _ in range(self.args.repeat):
                try:
                    answer = self.client.chat({"messages": [{"role": "system", "content": self.tag()},
                                                            {"role": "user", "content": REASONING_PROMPT}],
                                               "max_tokens": self.args.max_tokens, **extra})
                except Fail as err:
                    errors.append(f"{name}: {err}")
                    continue
                runs[name].append({"reasoning_chars": think_length(answer),
                                   "completion_tokens": answer["usage"].get("completion_tokens"),
                                   "seconds": round(answer["elapsed"], 2),
                                   "right": bool(re.search(REASONING_ANSWER, answer["content"]))})
            medians[name] = {k: median([r[k] for r in runs[name]]) for k in ("reasoning_chars", "completion_tokens", "seconds")}
            right = sum(r["right"] for r in runs[name])
            m = medians[name]
            say(f"    {name}: {rate(m['reasoning_chars'])} characters of reasoning, "
                f"{rate(m['completion_tokens'])} tokens, {secs(m['seconds'])} (medians), "
                f"{right}/{len(runs[name])} right")
        verdict, parts = {}, []
        base = medians["default"]
        for name, _ in variants[1:]:
            m = medians[name]
            if base["reasoning_chars"] or m["reasoning_chars"]:
                verdict[name] = changed(base["reasoning_chars"], m["reasoning_chars"])
            else:
                verdict[name] = changed(base["completion_tokens"], m["completion_tokens"])
            word = {True: "changed it", False: "changed nothing", None: "couldn't tell"}[verdict[name]]
            parts.append(f"{name} {word}")
        result = f"default {rate(base['reasoning_chars'])} characters of reasoning; " + "; ".join(parts)
        return {"status": "FAIL" if errors else "INFO", "target": f"override to {self.args.reasoning_effort}",
                "result": result, "runs": runs, "medians": medians, "changed": verdict, "notes": errors,
                "kwargs": kwargs}

    # -- throughput ----------------------------------------------------------------------------

    def throughput(self):
        rounds, errors, lines = {}, [], []
        for width in (1, 4):
            rounds[width] = []
            for r in range(self.args.repeat):
                got = self.burst(width, r)
                errors += [g["error"] for g in got["requests"] if g.get("error")]
                rounds[width].append(got)
            done = [g for rd in rounds[width] for g in rd["requests"] if not g.get("error")]
            decode = median([g.get("decode_per_second") for g in done])
            total = median([rd["tokens_per_second"] for rd in rounds[width]])
            prompt = median([g.get("prompt_per_second") for g in done])
            if width == 1:
                line = f"1 at a time: {rate(decode or total)} t/s"
            else:
                line = f"{width} at once: {rate(total)} t/s in all, {rate(decode)} t/s each"
            if prompt:
                line += f", prompt {prompt:.0f} t/s"
            lines.append(line)
            say(f"    {line}")
        throttled = sum(g.get("retries", 0) for w in rounds.values() for rd in w for g in rd["requests"])
        result = "; ".join(lines) + (f"; {throttled} x 429 retried" if throttled else "")
        notes = errors[:]
        if throttled:
            notes.append("nginx held this key to 2 requests at a time; --no-key through a tunnel measures the GPU alone")
        return {"status": "FAIL" if errors else "INFO", "target": "report", "result": result,
                "runs": rounds, "notes": notes, "throttled": throttled, "failed": len(errors)}

    def burst(self, width, r):
        out = [None] * width
        gate = threading.Barrier(width)

        def one(k):
            content = (f"{self.tag()}\nWrite about 400 words on a day in the life of a lighthouse keeper on a "
                       "remote island. Plain prose, no headings.")
            gate.wait()
            start = time.monotonic()
            try:
                a = self.client.chat({"messages": [{"role": "user", "content": content}],
                                      "max_tokens": THROUGHPUT_TOKENS})
            except Fail as err:
                out[k] = {"error": str(err), "start": start, "end": time.monotonic()}
                return
            tokens = a["usage"].get("completion_tokens") or a["timings"].get("predicted_n") or 0
            out[k] = {"start": start, "end": time.monotonic(), "tokens": tokens, "retries": a["retries"],
                      "seconds": round(a["elapsed"], 2),
                      "decode_per_second": a["timings"].get("predicted_per_second"),
                      "prompt_per_second": a["timings"].get("prompt_per_second")}

        threads = [threading.Thread(target=one, args=(k,), daemon=True) for k in range(width)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(self.args.timeout * 2)
        out = [o or {"error": "no answer in time", "start": time.monotonic(), "end": time.monotonic()} for o in out]
        wall = max(o["end"] for o in out) - min(o["start"] for o in out)
        tokens = sum(o.get("tokens", 0) for o in out)
        return {"seconds": round(wall, 2), "tokens": tokens, "tokens_per_second": tokens / wall if wall else None,
                "requests": [{k: v for k, v in o.items() if k not in ("start", "end")} for o in out]}

    # -- running it -------------------------------------------------------------------------------

    def run(self, name):
        say(f"\n== {name}")
        before = self.client.throttled
        started = time.monotonic()
        try:
            result = getattr(self, name.replace("-", "_"))()
        except Fail as err:
            result = {"status": "ERROR", "target": "", "result": str(err), "runs": [], "notes": []}
        except Exception as err:  # keep what the other scenarios found
            where = [f"{pathlib.Path(f.filename).name}:{f.lineno} in {f.name}: {f.line}"
                     for f in traceback.extract_tb(err.__traceback__)[-3:]]
            result = {"status": "ERROR", "target": "", "result": f"{type(err).__name__}: {err}", "runs": [],
                      "notes": where}
        result = {"scenario": name, **result, "seconds": round(time.monotonic() - started, 1),
                  "throttled": self.client.throttled - before}
        say(f"{result['status']:<5} {result['result']}")
        for note in result["notes"]:
            say(f"      {note}")
        return result


def table(results):
    rows = [("scenario", "runs", "status", "target", "result")]
    for r in results:
        runs = r["runs"]
        count = len(runs) if isinstance(runs, list) else sum(len(v) for v in runs.values())
        rows.append((r["scenario"], str(count), r["status"], r["target"], r["result"]))
    widths = [max(len(row[i]) for row in rows) for i in range(4)]
    return "\n".join("  ".join(cell.ljust(w) for cell, w in zip(row[:4], widths)) + "  " + row[4] for row in rows)


def canary_command(canary):
    return ("printf '%s\\n' " + canary + " | ssh inference 'c=$(cat); "
            "echo \"journal: $(sudo journalctl -o cat --no-pager | grep -cF -e \"$c\") line(s)\"; "
            "printf \"%s\\n\" \"$c\" | sudo grep -rlF --exclude-dir=models -f - "
            "/var/log /var/cache /var/lib /tmp /var/tmp | sed \"s/^/found in /\"; echo searched'")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--url", default="https://inference.servicestack.xyz/v1", help="the OpenAI-compatible base URL")
    ap.add_argument("--model", default="local", help="the model name to ask for")
    ap.add_argument("--label", default="local", help="which candidate this is, for the results file")
    ap.add_argument("--only", default=",".join(SCENARIOS), help=f"comma-separated, from {','.join(SCENARIOS)}")
    ap.add_argument("--repeat", type=int, default=5, help="runs of each scenario")
    ap.add_argument("--tools", help="Hermes' tool schemas, from a dumped request")
    ap.add_argument("--ha-tools", help="Home Assistant's tool schemas, from a dumped request")
    ap.add_argument("--out", help="where the JSON results go")
    ap.add_argument("--no-key", action="store_true", help="send no key, for llama-server through a tunnel")
    # Hermes allows far more; 12 leaves room for the bridge's search and
    # describe turns on top of the four or five calls a task needs.
    ap.add_argument("--max-turns", type=int, default=12, help="requests per agent conversation")
    ap.add_argument("--no-stream-tools", dest="stream_tools", action="store_false",
                    help="ask for agent turns all at once instead of streamed")
    ap.add_argument("--max-tokens", type=int, default=4096, help="for agent turns and checked answers")
    ap.add_argument("--voice-tokens", type=int, default=512)
    ap.add_argument("--load-tokens", type=int, default=50000, help="prompt size of the request voice-load runs against")
    ap.add_argument("--load-delay", type=float, default=1.0, help="seconds between that request and the voice one")
    ap.add_argument("--over-tokens", type=int, default=72000, help="prompt size of the request that must be refused")
    ap.add_argument("--reasoning-effort", default="high", help="what the reasoning overrides ask for")
    ap.add_argument("--reasoning-kwargs", help='chat_template_kwargs for the override, as JSON (default '
                    '{"reasoning_effort": <effort>, "enable_thinking": true})')
    ap.add_argument("--tool-target", type=float, default=0.95)
    ap.add_argument("--voice-target", type=float, default=1.5)
    ap.add_argument("--voice-load-target", type=float, default=4.0)
    ap.add_argument("--timeout", type=float, default=600, help="seconds a request may take")
    args = ap.parse_args()

    only = [s.strip() for s in args.only.split(",") if s.strip()]
    unknown = [s for s in only if s not in SCENARIOS]
    if unknown:
        sys.exit(f"unknown scenario(s) {', '.join(unknown)}; pick from {', '.join(SCENARIOS)}")
    if args.repeat < 1:
        sys.exit("--repeat has to be at least 1")
    if args.over_tokens <= CONTEXT_PER_SLOT:
        sys.exit(f"--over-tokens has to be over {CONTEXT_PER_SLOT}")
    if args.reasoning_kwargs:
        try:
            if not isinstance(json.loads(args.reasoning_kwargs), dict):
                raise ValueError
        except ValueError:
            sys.exit("--reasoning-kwargs has to be a JSON object")
    key = "" if args.no_key else os.environ.get("INFERENCE_KEY", "").strip()
    if not key and not args.no_key:
        sys.exit("INFERENCE_KEY isn't set; the top of this script says how to set it")
    if key:
        SECRETS.append(key)

    client = Client(args.url, key, args.model, args.timeout)
    tester = Tester(client, args)
    started = datetime.datetime.now()
    label = re.sub(r"[^A-Za-z0-9._-]+", "-", args.label)
    out = pathlib.Path(args.out or f"model-test-{label}-{started:%Y%m%d-%H%M%S}.json")
    say(f"model test of {args.label} at {args.url}, canary {tester.canary}")

    try:
        served = client.get("/models")
    except Fail as err:
        if err.status in (401, 403):
            sys.exit(scrub(f"the server refused the key (HTTP {err.status})"))
        sys.exit(scrub(f"couldn't list the models: {err}"))
    listed = served.get("data") if isinstance(served, dict) else None
    ids = [m.get("id") for m in listed or [] if isinstance(m, dict)]
    say(f"serving: {', '.join(map(str, ids)) or 'nothing listed'}")
    if args.model not in ids:
        say(f"warning: {args.model} isn't in the list")

    results, interrupted = [], False
    try:
        tester.calibrate()
        for name in only:
            results.append(tester.run(name))
    except KeyboardInterrupt:
        interrupted = True
        say("\ninterrupted; saving what's done")
    except Fail as err:
        say(f"\nstopped: {err}")
        results.append({"scenario": "calibration", "status": "ERROR", "target": "", "result": str(err),
                        "runs": [], "notes": []})

    report = {"label": args.label, "url": args.url, "model": args.model, "started": started.isoformat(timespec="seconds"),
              "finished": datetime.datetime.now().isoformat(timespec="seconds"), "interrupted": interrupted,
              "canary": tester.canary, "served": served, "calibration": tester.calibration,
              "options": vars(args), "results": results}
    try:
        out.write_text(scrub(json.dumps(report, indent=2, default=str)) + "\n")
        saved = f"results: {out}"
    except OSError as err:
        saved = f"couldn't write the results to {out}: {err}"

    say(f"\n== results for {args.label}")
    say(table(results))
    say(f"\n{saved}")
    say(f"\nThe canary for this run is {tester.canary}. Nothing on the host should have it; to look, run:\n")
    say("  " + canary_command(tester.canary))
    if interrupted or any(r["status"] in ("FAIL", "ERROR") for r in results):
        sys.exit(1)


if __name__ == "__main__":
    main()
