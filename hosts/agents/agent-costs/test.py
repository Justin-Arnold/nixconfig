#!/usr/bin/env python3
"""Runs agent-costs.py against a fake Paperclip and a fixture Hermes home.

The home has a state.db with Claude usage on the rate card, a Claude model
that isn't, and Codex usage that costs nothing; a jev.log with calls that
worked and one refused for credits; and an agent.log with Hermes' warning
that Claude refused for credits. The tests check the exact cents posted,
that only new spend is posted on later passes, that a pass that fails part
way picks up without counting twice, what month.json says, and that the
Paperclip key never shows up in the output.

usage: test.py <agent-costs.py>
"""
import datetime
import json
import os
import pathlib
import sqlite3
import stat
import subprocess
import sys
import tempfile
import threading
import time
from decimal import Decimal
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SCRIPT = sys.argv[1]
# Hermes logs local time. The agents host is in New York; a POSIX rule needs
# no time zone files, and the script gets the same one.
TZ = "EST5EDT,M3.2.0,M11.1.0"
os.environ["TZ"] = TZ
time.tzset()
KEY = "pcp_agent_" + "8f" * 16
AGENT_ID = "11111111-1111-4111-8111-111111111111"
COMPANY = "22222222-2222-4222-8222-222222222222"
TMP = pathlib.Path(tempfile.mkdtemp())
HOME = TMP / "hermes"
OUT = TMP / "out"
NOW = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
failures = []


def check(what, ok):
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        failures.append(what)


class Fake:
    def __init__(self):
        self.events, self.requests, self.fail_after, self.reject_key = {}, [], None, False


fake = Fake()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        fake.requests.append(("GET", self.path))
        if self.headers.get("Authorization") != f"Bearer {KEY}" or fake.reject_key:
            return self.reply(401, {"error": f"bad key {self.headers.get('Authorization')}"})
        if self.path == "/api/agents/me":
            return self.reply(200, {"id": AGENT_ID, "companyId": COMPANY, "name": "Reviewer"})
        self.reply(404, {})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        fake.requests.append(("POST", self.path))
        if self.path != f"/api/companies/{COMPANY}/cost-events":
            return self.reply(404, {})
        if fake.fail_after is not None:
            if fake.fail_after == 0:
                return self.reply(500, {"error": "database is having a moment"})
            fake.fail_after -= 1
        key = body.get("idempotencyKey")
        if key in fake.events:
            if fake.events[key] != body:
                return self.reply(409, {"error": "Idempotency key already used for a different cost receipt"})
            return self.reply(201, body)
        fake.events[key] = body
        self.reply(201, body)


httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=httpd.serve_forever, daemon=True).start()

# The fixture home.
(HOME / "logs").mkdir(parents=True)
OUT.mkdir()
db = sqlite3.connect(HOME / "state.db")
db.execute("""CREATE TABLE session_model_usage (session_id TEXT, model TEXT, billing_provider TEXT DEFAULT '',
  billing_base_url TEXT DEFAULT '', billing_mode TEXT DEFAULT '', task TEXT DEFAULT '', api_call_count INTEGER,
  input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER, cache_write_tokens INTEGER,
  reasoning_tokens INTEGER DEFAULT 0, estimated_cost_usd REAL, actual_cost_usd REAL DEFAULT 0, cost_status TEXT,
  cost_source TEXT, first_seen REAL, last_seen REAL)""")
T = NOW.timestamp() - 600


def row(session, model, provider, calls, inp, out, cache_read, cache_write, estimate, task=""):
    db.execute("INSERT INTO session_model_usage (session_id, model, billing_provider, task, api_call_count, input_tokens, "
               "output_tokens, cache_read_tokens, cache_write_tokens, estimated_cost_usd, first_seen, last_seen) "
               "VALUES (?,?,?,?,?,?,?,?,?,?,?,?)", (session, model, provider, task, calls, inp, out, cache_read,
                                                  cache_write, estimate, T - 60, T))


# $4/$20 a million: 100k in, 20k out, 10k cache write at 1.25x, 500k cache read at 0.1x = 105 cents.
row("s1", "claude-opus-5-5", "anthropic", 3, 100_000, 20_000, 500_000, 10_000, 9.99)
# $2/$10: 50k in, 5k out = 15 cents.
row("s1", "claude-sonnet-5-5", "anthropic", 1, 50_000, 5_000, 0, 0, 0)
# Not on the rate card: Hermes' estimate, $0.37.
row("s2", "claude-fable-5-1", "anthropic", 1, 1_000, 100, 0, 0, 0.37, task="compression")
# Included in the ChatGPT plan: never reported.
row("s1", "gpt-6.1-sol", "openai-codex", 5, 900_000, 9_000, 0, 0, 0)
db.commit()

ok_at = (NOW - datetime.timedelta(minutes=30)).strftime("%Y-%m-%dT%H:%M:%SZ")
refused_at = (NOW - datetime.timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ")
(HOME / "logs" / "jev.log").write_text(
    f"{ok_at} call=aaaaaaaaaaaa questions=1 status=ok model=jev-1.14.0 input_tokens=1000000\n"
    f"{ok_at} call=bbbbbbbbbbbb questions=2 status=ok model=jev-1.14.0 input_tokens=500\n"
    f"{ok_at} call=cccccccccccc questions=1 status=refused\n"
    f"{refused_at} call=dddddddddddd questions=1 status=refused reason=billing\n")
# Hermes logs local time.
warned = (NOW - datetime.timedelta(minutes=2)).astimezone()
(HOME / "logs" / "agent.log.1").write_text(
    f"{warned:%Y-%m-%d %H:%M:%S},123 WARNING agent.chat_completion_helpers: Profile default: claude-opus-5-5 via "
    "anthropic refused for billing/credits — using fallback claude-sonnet-5-5 via anthropic. Top up credits.\n"
    f"{warned:%Y-%m-%d %H:%M:%S},456 INFO agent: Fallback activated: a → b (anthropic)\n")

creds = TMP / "creds"
creds.mkdir()
(creds / "paperclip-key").write_text(KEY + "\n")
ENV = {"PATH": os.environ.get("PATH", ""), "AGENT": "reviewer", "HERMES_HOME": str(HOME), "OUT_DIR": str(OUT),
       "PAPERCLIP_URL": f"http://127.0.0.1:{httpd.server_address[1]}", "CREDENTIALS_DIRECTORY": str(creds),
       "JEV_CENTS_PER_MILLION": "4.2", "TZ": TZ,
       "PRICES": json.dumps({"claude-opus-5-5": {"input": 4, "output": 20}, "claude-sonnet-5-5": {"input": 2, "output": 10}})}


def run():
    proc = subprocess.run([sys.executable, "-I", SCRIPT], capture_output=True, text=True, env=ENV, timeout=60)
    run.output = proc.stdout + proc.stderr
    print(run.output, end="")
    return proc.returncode


def month():
    return json.loads((OUT / "month.json").read_text())


def total(model=None, provider=None):
    return sum(Decimal(e["costCents"]) for e in fake.events.values()
               if (model is None or e["model"] == model) and (provider is None or e["provider"] == provider))


check("a first pass succeeds", run() == 0)
by_model = {e["model"]: e for e in fake.events.values() if e["provider"] == "anthropic"}
check("it reports Opus at the rate card, with cache: 105 cents", by_model["claude-opus-5-5"]["costCents"] == "105")
check("and Sonnet: 15 cents", by_model["claude-sonnet-5-5"]["costCents"] == "15")
check("a Claude model off the rate card falls back to Hermes' estimate, marked unknown",
      by_model["claude-fable-5-1"]["costCents"] == "37" and by_model["claude-fable-5-1"]["pricingProvenance"]["source"] == "unknown")
check("Codex isn't reported", not any(e["model"].startswith("gpt") for e in fake.events.values()))
opus = by_model["claude-opus-5-5"]
check("events are the agent's own, estimated, metered, without token counts",
      opus["agentId"] == AGENT_ID and opus["costStatus"] == "estimated" and opus["billingType"] == "metered_api"
      and opus["biller"] == "anthropic" and not any(k.endswith("Tokens") for k in opus))
check("the rate card and the tokens are in the provenance",
      opus["pricingProvenance"]["inputCentsPerMillion"] == "400" and "100000 in" in opus["pricingProvenance"]["evidence"])
jev = sorted((e for e in fake.events.values() if e["provider"] == "typesafe"), key=lambda e: e["idempotencyKey"])
check("Jev calls that worked are reported at 4.2 cents a million input tokens",
      [e["costCents"] for e in jev] == ["4.2", "0.0021"] and jev[0]["idempotencyKey"] == "jev:reviewer:aaaaaaaaaaaa")
check("refused Jev calls aren't", len(jev) == 2)
check("idempotency keys never use Paperclip's reserved heartbeat: namespace",
      not any(k.startswith("heartbeat:") for k in fake.events))

m = month()
check("month.json has this month's Claude and Jev cents", m["claude"]["cents"] == "157" and m["jev"]["cents"] == "4.2021")
check("it says when Claude last refused for credits, from Hermes' local-time log",
      m["claude"]["last_refused"] == warned.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"))
check("and when Claude last worked", m["claude"]["last_ok"] == datetime.datetime.fromtimestamp(T, datetime.timezone.utc)
      .strftime("%Y-%m-%dT%H:%M:%S.000Z"))
check("and the same for Jev", m["jev"]["last_ok"] == ok_at.replace("Z", ".000Z") and m["jev"]["last_refused"] == refused_at.replace("Z", ".000Z"))
check("month.json is readable by agent-watch", stat.S_IMODE((OUT / "month.json").stat().st_mode) == 0o644)
check("nothing it wrote holds the key", KEY not in (OUT / "month.json").read_text() + (OUT / "posted.json").read_text())

count = len(fake.events)
posts = sum(1 for m_, _ in fake.requests if m_ == "POST")
check("a pass with nothing new posts nothing", run() == 0 and sum(1 for m_, _ in fake.requests if m_ == "POST") == posts)

db.execute("UPDATE session_model_usage SET api_call_count = 4, input_tokens = 200000, last_seen = ? "
           "WHERE model = 'claude-opus-5-5'", (T + 60,))
db.commit()
check("more Opus use is a pass that succeeds", run() == 0)
new = [e for k, e in fake.events.items() if e["model"] == "claude-opus-5-5"]
check("only the difference is posted: 40 cents more", sorted(e["costCents"] for e in new) == ["105", "40"]
      and total("claude-opus-5-5") == Decimal("145"))
check("month.json adds it up", month()["claude"]["cents"] == "197")

db.execute("UPDATE session_model_usage SET api_call_count = 5, input_tokens = 300000 WHERE model = 'claude-opus-5-5'")
db.execute("UPDATE session_model_usage SET api_call_count = 2, output_tokens = 10000 WHERE model = 'claude-sonnet-5-5'")
db.commit()
fake.fail_after = 1
check("a pass where Paperclip fails part way fails", run() != 0)
fake.fail_after = None
check("the next pass posts the rest without counting anything twice",
      run() == 0 and total("claude-opus-5-5") == Decimal("185") and total("claude-sonnet-5-5") == Decimal("20"))
check("month.json agrees with Paperclip", Decimal(month()["claude"]["cents"]) == total(provider="anthropic"))

fake.reject_key = True
(HOME / "logs" / "jev.log").write_text((HOME / "logs" / "jev.log").read_text()
                                       + f"{ok_at} call=eeeeeeeeeeee questions=1 status=ok input_tokens=10\n")
check("a refused key fails the pass without printing the key", run() != 0 and "HTTP 401" in run.output and KEY not in run.output)

httpd.shutdown()
if failures:
    sys.exit(f"{len(failures)} check(s) failed")
print("all checks passed")
