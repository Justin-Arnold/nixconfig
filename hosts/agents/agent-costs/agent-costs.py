#!/usr/bin/env python3
"""agent-costs: one agent's Claude and Jev spend, reported to Paperclip.

One pass for one agent, run as that agent's user by a timer on the agents
host (hosts/agents/agent-costs.nix). It reads only that agent's own files:

  state.db      Hermes' usage per session, model and task
                (session_model_usage), which covers fallbacks and side tasks
  logs/jev.log  the Jev server's calls, with their input tokens
  logs/agent.log*  for Hermes' warning when Claude refuses for credits

Claude is priced from its tokens with the rate card in PRICES, since
Hermes' own table doesn't know every model. Jev costs JEV_CENTS_PER_MILLION
input tokens, and its output is free. What's new since the last pass goes to
Paperclip as cost events under the agent's own key, each with a key that
makes a retry harmless. They carry no token counts, because the run's own
event already does.

It writes OUT_DIR/month.json for agent-watch: this month's cents, and when
Claude and Jev last worked and last refused for credits. Nothing in it is
secret. OUT_DIR/posted.json remembers what's been reported.

Environment: AGENT, HERMES_HOME, OUT_DIR, PAPERCLIP_URL, PRICES (JSON:
model -> {"input": dollars, "output": dollars} per million tokens),
JEV_CENTS_PER_MILLION, and CREDENTIALS_DIRECTORY holding paperclip-key.
"""
import datetime
import glob
import hashlib
import json
import os
import pathlib
import re
import sqlite3
import sys
import urllib.error
import urllib.request
from decimal import Decimal

CACHE_WRITE = Decimal("1.25")
CACHE_READ = Decimal("0.1")
MILLION = Decimal(1_000_000)
# Hermes' warning when a provider refuses for credits and it moves to a fallback.
CLAUDE_REFUSED = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)[,.]\d+ .* via anthropic refused for billing/credits")
JEV_LINE = re.compile(r"^(\S+) call=([0-9a-f]{12}) questions=\d+ status=(\w+)(.*)$")


def now():
    return datetime.datetime.now(datetime.timezone.utc)


def iso(moment):
    return moment.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z") if moment else None


def month_of(moment):
    return moment.astimezone(datetime.timezone.utc).strftime("%Y-%m")


def cents(value):
    """A Decimal as Paperclip's exact-cents string."""
    return format(value.quantize(Decimal("0.000001")).normalize(), "f")


def credential(name):
    return (pathlib.Path(os.environ["CREDENTIALS_DIRECTORY"]) / name).read_text().strip()


def request(method, url, key, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Accept": "application/json", "Authorization": f"Bearer {key}",
        **({"Content-Type": "application/json"} if data else {})})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as err:
        detail = " ".join(err.read(300).decode(errors="replace").split()).replace(key, "***")
        raise SystemExit(f"{method} {url.split('?')[0]} failed: HTTP {err.code} {detail}") from None
    except urllib.error.URLError as err:
        raise SystemExit(f"cannot reach {url.split('?')[0]}: {err.reason}") from None


def claude_rows(home):
    """Hermes' Anthropic usage rows, one per session, model, endpoint and task."""
    db = pathlib.Path(home) / "state.db"
    if not db.exists():
        return []
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    try:
        con.row_factory = sqlite3.Row
        return [dict(r) for r in con.execute(
            "SELECT session_id, model, billing_provider, billing_base_url, billing_mode, task, api_call_count, "
            "input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, estimated_cost_usd, last_seen "
            "FROM session_model_usage WHERE billing_provider = 'anthropic' OR model LIKE 'claude%'")]
    finally:
        con.close()


def price(row, prices):
    """(cents, provenance) for a row's tokens so far."""
    rate = prices.get(row["model"])
    if rate is None:
        # Not on the rate card: Hermes' own estimate, marked as such.
        return Decimal(str(row["estimated_cost_usd"] or 0)) * 100, {"source": "unknown", "evidence": "Hermes estimate"}
    inp, out = Decimal(str(rate["input"])) * 100, Decimal(str(rate["output"])) * 100
    total = (inp * row["input_tokens"] + out * row["output_tokens"]
             + inp * CACHE_WRITE * row["cache_write_tokens"] + inp * CACHE_READ * row["cache_read_tokens"]) / MILLION
    return total, {"source": "rate_card", "version": "nixconfig", "inputCentsPerMillion": cents(inp),
                   "outputCentsPerMillion": cents(out), "cacheWriteCentsPerMillion": cents(inp * CACHE_WRITE),
                   "cachedInputCentsPerMillion": cents(inp * CACHE_READ),
                   "evidence": (f"{row['input_tokens']} in, {row['output_tokens']} out, {row['cache_write_tokens']} "
                                f"cache write, {row['cache_read_tokens']} cache read, {row['api_call_count']} calls")}


def claude_refusals(home):
    """When Hermes last said Claude refused for credits, from the agent's logs."""
    last = None
    for path in glob.glob(str(pathlib.Path(home) / "logs" / "agent.log*")):
        try:
            with open(path, errors="replace") as f:
                for line in f:
                    m = CLAUDE_REFUSED.match(line)
                    if m:
                        # Hermes writes local time.
                        moment = datetime.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S").astimezone()
                        last = max(last or moment, moment)
        except OSError:
            continue
    return last


def jev_calls(home):
    """(ok calls with their tokens, last ok time, last billing refusal time) from jev.log."""
    path = pathlib.Path(home) / "logs" / "jev.log"
    calls, last_ok, last_refused = [], None, None
    if not path.exists():
        return calls, last_ok, last_refused
    for line in path.read_text(errors="replace").splitlines():
        m = JEV_LINE.match(line)
        if not m:
            continue
        moment = datetime.datetime.fromisoformat(m.group(1).replace("Z", "+00:00"))
        if m.group(3) == "ok":
            tokens = re.search(r"input_tokens=(\d+)", m.group(4))
            calls.append((m.group(2), moment, int(tokens.group(1)) if tokens else 0))
            last_ok = max(last_ok or moment, moment)
        elif "reason=billing" in m.group(4):
            last_refused = max(last_refused or moment, moment)
    return calls, last_ok, last_refused


def main():
    agent = os.environ["AGENT"]
    home = os.environ["HERMES_HOME"]
    out = pathlib.Path(os.environ["OUT_DIR"])
    paperclip = os.environ.get("PAPERCLIP_URL", "http://127.0.0.1:3100").rstrip("/")
    prices = json.loads(os.environ.get("PRICES", "{}"))
    jev_rate = Decimal(os.environ.get("JEV_CENTS_PER_MILLION", "4.2"))
    key = credential("paperclip-key")

    state_path = out / "posted.json"
    state = json.loads(state_path.read_text()) if state_path.exists() else {}
    posted = state.setdefault("claude", {})
    jev_posted = set(state.setdefault("jev", []))
    months = state.setdefault("months", {})

    events = []
    rows = claude_rows(home)
    claude_last_ok = None
    for row in rows:
        ident = "|".join(str(row[k]) for k in ("session_id", "model", "billing_base_url", "billing_mode", "task"))
        total, provenance = price(row, prices)
        delta = total - Decimal(posted.get(ident, "0"))
        seen = datetime.datetime.fromtimestamp(row["last_seen"] or 0, datetime.timezone.utc)
        if row["api_call_count"]:
            claude_last_ok = max(claude_last_ok or seen, seen)
        if delta > 0:
            events.append(("claude", ident, cents(total), delta, seen, {
                "provider": "anthropic", "biller": "anthropic", "model": row["model"],
                "billingType": "metered_api", "costStatus": "estimated", "costCents": cents(delta),
                "occurredAt": iso(seen), "pricingProvenance": provenance,
                "idempotencyKey": (f"hermes:{agent}:{hashlib.sha256(ident.encode()).hexdigest()[:24]}:"
                                   f"{row['api_call_count']}:{cents(total)}")[:200]}))

    calls, jev_last_ok, jev_last_refused = jev_calls(home)
    for call_id, moment, tokens in calls:
        if call_id in jev_posted:
            continue
        cost = jev_rate * tokens / MILLION
        events.append(("jev", call_id, None, cost, moment, {
            "provider": "typesafe", "biller": "typesafe", "model": "jev", "billingType": "metered_api",
            "costStatus": "estimated", "costCents": cents(cost), "occurredAt": iso(moment),
            "pricingProvenance": {"source": "rate_card", "version": "nixconfig", "inputCentsPerMillion": cents(jev_rate),
                                  "evidence": f"{tokens} input tokens"},
            "idempotencyKey": f"jev:{agent}:{call_id}"}))

    if events:
        me = request("GET", f"{paperclip}/api/agents/me", key)
        url = f"{paperclip}/api/companies/{me['companyId']}/cost-events"
    for kind, ident, total, delta, moment, body in events:
        request("POST", url, key, {"agentId": me["id"], **body})
        # Remembered one by one, so a failure part-way loses nothing.
        if kind == "claude":
            posted[ident] = total
        else:
            jev_posted.add(ident)
        month = months.setdefault(month_of(moment), {"claude": "0", "jev": "0"})
        month[kind] = cents(Decimal(month[kind]) + delta)
        state["jev"] = sorted(jev_posted)
        tmp = state_path.with_suffix(".tmp")
        tmp.write_text(json.dumps(state, indent=1))
        tmp.replace(state_path)

    this = months.get(month_of(now()), {"claude": "0", "jev": "0"})
    summary = {
        "agent": agent, "month": month_of(now()), "updated": iso(now()),
        "claude": {"cents": this["claude"], "last_ok": iso(claude_last_ok), "last_refused": iso(claude_refusals(home))},
        "jev": {"cents": this["jev"], "last_ok": iso(jev_last_ok), "last_refused": iso(jev_last_refused)},
    }
    tmp = out / "month.json.tmp"
    tmp.write_text(json.dumps(summary, indent=1))
    os.chmod(tmp, 0o644)
    tmp.replace(out / "month.json")
    print(f"{agent}: {len(events)} cost event(s) posted; this month Claude {summary['claude']['cents']}¢, "
          f"Jev {summary['jev']['cents']}¢")


if __name__ == "__main__":
    main()
