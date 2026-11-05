#!/usr/bin/env python3
"""Jev, TypeSafe's decision model, as one MCP tool for a Hermes agent.

Hermes starts this over stdio. Its one tool, `decide`, sends a piece of text
and some typed questions to Jev's System One API and returns calibrated
answers: the probability of yes, a probability for each choice, or a score
on a scale. It writes nothing but each call's id, time, size and outcome to
the call log, never the text, the questions or the answers.

The endpoint is any System One server (`POST <base>/systemone`): TypeSafe's
by default, or a local one later. It takes these from the environment:

  JEV_API_KEY    the key, sent as a bearer token and never printed
  JEV_BASE_URL   https://api.typesafe.ai/v1 by default; HTTPS, or HTTP to
                 loopback only
  JEV_MODEL      jev-1.14.0 by default, a pinned version so answers stay
                 comparable
  JEV_CALL_LOG   where the call log goes; none when unset
  JEV_DEADLINE   seconds a call may take in all, retries included (45),
                 under Hermes' 60 s tool timeout
"""
import datetime
import json
import os
import re
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BASE_URL = os.environ.get("JEV_BASE_URL", "https://api.typesafe.ai/v1").rstrip("/")
MODEL = os.environ.get("JEV_MODEL", "jev-1.14.0")
CALL_LOG = os.environ.get("JEV_CALL_LOG") or None
DEADLINE = float(os.environ.get("JEV_DEADLINE", "45"))

# Jev reads 64K tokens per request and 32K per question by default. Staying
# well under that keeps every call off the slower long-context mode, and the
# cost of one at about a tenth of a cent at most.
MAX_STATE_CHARS = 60_000
MAX_QUESTIONS = 16
MAX_INSTRUCTIONS = 2_000
MAX_CRITERION = 500
QUESTION_NAME = re.compile(r"[A-Za-z][A-Za-z0-9_.-]{0,63}")
TYPES = {"noul", "choice", "score"}
RETRIES_429 = 2

# Things that are never Jev's to see. Matched against the whole request.
SECRET_PATTERNS = [
    (re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----"), "a private key"),
    (re.compile(r"\bAGE-SECRET-KEY-1[0-9A-Z]{40,}"), "an age secret key"),
    (re.compile(r"\bsk-ant-[A-Za-z0-9_-]{20,}"), "an Anthropic key"),
    (re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9_-]{32,}"), "an API key"),
    (re.compile(r"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}|\bgithub_pat_[A-Za-z0-9_]{40,}"), "a GitHub token"),
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "an AWS access key"),
    (re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}"), "a Slack token"),
    (re.compile(r"\bpcp_[A-Za-z0-9_]{20,}"), "a Paperclip key"),
    (re.compile(r"(?i)\b(?:password|passwd|secret|token|api[_-]?key)\s*[:=]\s*\S{8,}"), "something that looks like a credential"),
]

DESCRIPTION = """Ask Jev, a decision model, typed questions about a piece of text and get \
calibrated probabilities back. Use it when a decision should be a measured yes/no, a pick \
from fixed options, or a score on a scale, rather than your own guess. It's advisory: you \
decide what to do with the answer, and a "yes" is never an approval.

Jev is an outside service (TypeSafe) that may keep what you send. Send only text from \
Paperclip issues or public sources. Never send secrets, keys, personal data, private \
files, or anything you'd consider sensitive; requests that look like they hold a secret \
are refused.

state: the text the questions are about (a string, or a JSON object or array), at most \
60,000 characters.

questions: 1 to 16 named questions, each answered on its own against the same state:
- {"type": "noul", "instructions": "Does this need a human today?", \
"criteria": {"true": "...", "false": "..."}} returns `noul`, the probability of yes. \
criteria is optional.
- {"type": "choice", "instructions": "Which team owns this?", \
"criteria": {"billing": "Invoices and charges", "technical": "Errors and outages"}} \
returns `choice`, `probabilities` and `confidence`. 1 to 255 options; a description \
can be null.
- {"type": "score", "instructions": "How urgent is this?", \
"criteria": ["Routine", "This week", "Today", "Now"]} returns `score` (0 is the first \
level), `probabilities`, `legend` and `confidence`. 1 to 10 levels, lowest first.

Write instructions as a plain question about the state, and make the criteria distinct. \
The result has `call_id`, `model`, `answers` (keyed by your question names) and `usage`."""


class Refused(Exception):
    """A request this tool won't send, or an answer it couldn't get. reason
    is "billing" when TypeSafe refused for credits, so the call log can say."""

    def __init__(self, message, reason=None):
        super().__init__(message)
        self.reason = reason


# TypeSafe's ways of saying the account has no credit left.
BILLING = re.compile(r"(?i)credit|balance|quota|payment|billing")


def _text(value, limit):
    if not isinstance(value, str) or not value.strip():
        return None
    if len(value) > limit:
        raise Refused(f"a text over {limit} characters")
    return value


def check_questions(questions):
    """The questions as Jev wants them, or Refused saying what's wrong."""
    if not isinstance(questions, dict) or not questions:
        raise Refused("questions must be an object of 1 to 16 named questions")
    if len(questions) > MAX_QUESTIONS:
        raise Refused(f"at most {MAX_QUESTIONS} questions per call (got {len(questions)})")
    out = {}
    for name, q in questions.items():
        where = f"question {name!r}"
        if not isinstance(name, str) or not QUESTION_NAME.fullmatch(name):
            raise Refused(f"{where}: names are letters, digits, _ . - (up to 64), starting with a letter")
        if not isinstance(q, dict):
            raise Refused(f"{where} must be an object with a type")
        extra = set(q) - {"type", "instructions", "criteria"}
        if extra:
            raise Refused(f"{where} has keys Jev doesn't take: {', '.join(sorted(extra))}")
        kind = q.get("type")
        if kind not in TYPES:
            raise Refused(f"{where}: type must be noul, choice or score (got {kind!r})")
        item = {"type": kind}
        try:
            instructions = _text(q.get("instructions"), MAX_INSTRUCTIONS)
        except Refused as err:
            raise Refused(f"{where}: instructions are {err}") from None
        if instructions:
            item["instructions"] = instructions
        criteria = q.get("criteria")
        if kind == "noul":
            if criteria is not None:
                if not isinstance(criteria, dict) or not criteria or set(criteria) - {"true", "false"}:
                    raise Refused(f"{where}: noul criteria are an object with \"true\" and/or \"false\"")
                item["criteria"] = {k: _criterion(v, where) for k, v in criteria.items()}
        elif kind == "choice":
            if not isinstance(criteria, dict) or not 1 <= len(criteria) <= 255:
                raise Refused(f"{where}: choice criteria are an object of 1 to 255 options")
            for option in criteria:
                if not isinstance(option, str) or not option.strip() or len(option) > 64:
                    raise Refused(f"{where}: option names are 1 to 64 characters")
            item["criteria"] = {k: (None if v is None else _criterion(v, where)) for k, v in criteria.items()}
        else:
            if not isinstance(criteria, list) or not 1 <= len(criteria) <= 10:
                raise Refused(f"{where}: score criteria are a list of 1 to 10 levels, lowest first")
            item["criteria"] = [_criterion(v, where) for v in criteria]
        out[name] = item
    return out


def _criterion(value, where):
    if not isinstance(value, str) or not value.strip():
        raise Refused(f"{where}: every criterion is a non-empty string")
    if len(value) > MAX_CRITERION:
        raise Refused(f"{where}: a criterion is over {MAX_CRITERION} characters")
    return value


def check_state(state):
    if isinstance(state, str):
        size = len(state)
    elif isinstance(state, (dict, list)):
        size = len(json.dumps(state, ensure_ascii=False))
    else:
        raise Refused("state must be a string, or a JSON object or array")
    if size == 0 or (isinstance(state, str) and not state.strip()):
        raise Refused("state is empty")
    if size > MAX_STATE_CHARS:
        raise Refused(f"state is {size} characters; at most {MAX_STATE_CHARS}")
    return state


def check_secrets(body):
    text = json.dumps(body, ensure_ascii=False)
    for pattern, what in SECRET_PATTERNS:
        if pattern.search(text):
            raise Refused(f"the request looks like it holds {what}, which never goes to Jev; take it out and ask again")


def check_endpoint(url):
    parts = urllib.parse.urlsplit(url)
    if parts.scheme == "https" and parts.hostname:
        return
    if parts.scheme == "http" and parts.hostname in ("127.0.0.1", "localhost", "::1"):
        return
    raise Refused(f"JEV_BASE_URL must be HTTPS (or HTTP to loopback), not {url}")


def _retry_after(value):
    try:
        return max(0.0, float(value))
    except (TypeError, ValueError):
        return None


def _scrub(text, key):
    return text.replace(key, "***") if key else text


def post(body, key):
    """Jev's answer, retrying a 429 after its Retry-After within the deadline."""
    data = json.dumps(body).encode()
    deadline = time.monotonic() + DEADLINE
    for attempt in range(RETRIES_429 + 1):
        left = deadline - time.monotonic()
        if left <= 1:
            raise Refused(f"Jev didn't answer within {DEADLINE:.0f} s")
        req = urllib.request.Request(f"{BASE_URL}/systemone", data=data, method="POST", headers={
            "Authorization": f"Bearer {key}", "Content-Type": "application/json", "Accept": "application/json",
            "User-Agent": "lab-jev-mcp/1"})
        try:
            with urllib.request.urlopen(req, timeout=left) as resp:
                return json.load(resp)
        except urllib.error.HTTPError as err:
            detail = _scrub(err.read(2000).decode("utf-8", "replace"), key)
            if err.code == 429 and attempt < RETRIES_429:
                wait = _retry_after(err.headers.get("Retry-After"))
                wait = 2.0 if wait is None else wait
                if time.monotonic() + wait < deadline - 2:
                    time.sleep(wait)
                    continue
            billing = err.code == 402 or (err.code in (400, 403) and bool(BILLING.search(detail)))
            raise Refused(f"Jev answered HTTP {err.code}: {' '.join(detail.split())[:300]}",
                          "billing" if billing else None) from None
        except (urllib.error.URLError, TimeoutError, OSError) as err:
            reason = getattr(err, "reason", err)
            raise Refused(f"couldn't reach Jev: {_scrub(str(reason), key)}") from None
        except ValueError:
            raise Refused("Jev's answer wasn't JSON") from None
    raise Refused("Jev was still rate-limiting after retries")


def log_call(call_id, questions, status, model=None, tokens=None, reason=None):
    """One line per call: never the state, the questions or the answers."""
    if not CALL_LOG:
        return
    when = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    line = f"{when} call={call_id} questions={questions} status={status}"
    if reason:
        line += f" reason={reason}"
    if model:
        line += f" model={model}"
    if tokens is not None:
        line += f" input_tokens={tokens}"
    try:
        fd = os.open(CALL_LOG, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        with os.fdopen(fd, "a") as f:
            f.write(line + "\n")
    except OSError as err:
        print(f"jev: couldn't write the call log: {err}", file=sys.stderr)


def decide(state, questions):
    """The tool: checks, one call to Jev, and the answers with this call's id."""
    call_id = secrets.token_hex(6)
    count = len(questions) if isinstance(questions, dict) else 0
    try:
        key = os.environ.get("JEV_API_KEY", "")
        if not key:
            raise Refused("there's no JEV_API_KEY")
        check_endpoint(BASE_URL)
        body = {"model": MODEL, "state": check_state(state), "questions": check_questions(questions)}
        check_secrets(body)
        answer = post(body, key)
        if not isinstance(answer, dict) or not isinstance(answer.get("answers"), dict):
            raise Refused("Jev's answer had no answers")
    except Refused as err:
        log_call(call_id, count, "refused", reason=err.reason)
        raise Refused(f"{err} (call {call_id})", err.reason) from None
    usage = answer.get("usage") if isinstance(answer.get("usage"), dict) else {}
    model = answer.get("model") or MODEL
    log_call(call_id, count, "ok", model, usage.get("input_tokens"))
    return {"call_id": call_id, "model": model, "answers": answer["answers"], "usage": usage}


def main():
    from mcp.server.mcpserver import MCPServer
    from mcp.server.mcpserver.exceptions import ToolError
    from mcp.types import ToolAnnotations

    server = MCPServer("jev")

    @server.tool(name="decide", description=DESCRIPTION, structured_output=False,
                 annotations=ToolAnnotations(title="Ask Jev", readOnlyHint=True, idempotentHint=True,
                                             destructiveHint=False, openWorldHint=True))
    def decide_tool(state: str | dict | list, questions: dict) -> str:
        try:
            return json.dumps(decide(state, questions), ensure_ascii=False)
        except Refused as err:
            # Only a ToolError's message reaches the agent; anything else
            # comes back as a bare "Error executing tool".
            raise ToolError(str(err)) from None

    server.run()


if __name__ == "__main__":
    main()
