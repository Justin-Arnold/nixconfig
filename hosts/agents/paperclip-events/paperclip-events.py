#!/usr/bin/env python3
"""paperclip-events: Paperclip's live events, as a nudge to each service on
the agents host that acts on them.

A long-running service on the agents host (hosts/agents/paperclip-events.nix).
It holds Paperclip's live websocket for the company, which takes an agent
key and nothing else. For each event that matters to a consumer, it leaves a
file named `pending` in EVENTS_DIR/<consumer>.d/. A path unit starts the
consumer while that folder isn't empty, and the consumer empties it as it
starts. So an event that comes during a pass causes exactly one more pass,
and a burst of events causes one.

Paperclip's events only say that something changed: an activity's action
and the id of what it's about, or a run's status. Each consumer then reads
what it needs from Paperclip itself, as it did when it ran on a timer. The
relay passes nothing on but "look again", so nothing in an event can steer
a consumer. Who wants what is in targets():

- agent-watch: questions, confirmations and approvals coming and going,
  issues created or changed, runs that finished, agents' status;
- board-bridge: questions, confirmations and approvals coming and going;
- monitor-intake: issues created or changed, so a finished triage releases
  the alerts waiting behind it at once;
- agent-costs-<name>: each finished run of that agent.

After every (re)connect every consumer is nudged once, for whatever
happened while the relay was away. The consumers' own timers stay as a
slow sweep, and for what's about time passing.

STATE_DIR/status.json says whether it's connected, when it last knew it was
(last_ok, kept fresh every minute while connected), what last went wrong,
and how many nudges each consumer got, for agent-watch's EventsStale. It
holds no secret.

Environment: PAPERCLIP_URL, EVENTS_DIR, STATE_DIR, CONSUMERS (space
separated), COST_AGENTS (the agents with an agent-costs-<name>, space
separated), and CREDENTIALS_DIRECTORY holding paperclip-key.
"""
import asyncio
import datetime
import json
import logging
import os
import pathlib
import sys

import aiohttp

log = logging.getLogger("paperclip-events")

# Activity actions, as Paperclip 2026.1023.0 logs them.
INTERACTIONS = "issue.thread_interaction_"  # created, answered, accepted, rejected, expired, ...
APPROVALS = "approval."  # created, approved, rejected, revision_requested, resubmitted, ...
ISSUE_STATE = frozenset({"issue.created", "issue.updated", "issue.deleted", "issue.released", "issue.checked_out"})

# How long to wait before connecting again, doubling up to the last.
BACKOFF = (1, 2, 4, 8, 15, 30, 60)
# A connection that lasted this long starts the backoff over.
STEADY = 60


class Failure(Exception):
    """Paperclip wouldn't say who the key is or which agents there are."""


def now():
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)


def iso(moment):
    return moment.isoformat().replace("+00:00", "Z")


def targets(event, agents):
    """The consumers an event matters to. agents maps agent ids to the
    names their agent-costs units go by."""
    if not isinstance(event, dict):
        return set()
    kind = event.get("type")
    payload = event.get("payload")
    if not isinstance(payload, dict):
        payload = {}
    found = set()
    if kind == "activity.logged":
        action = payload.get("action")
        if not isinstance(action, str):
            return found
        if action.startswith(INTERACTIONS) or action.startswith(APPROVALS):
            found |= {"agent-watch", "board-bridge"}
        if action in ISSUE_STATE:
            found |= {"agent-watch", "monitor-intake"}
    elif kind == "heartbeat.run.status":
        # A run's status changes several times; only its end matters here.
        if payload.get("finishedAt"):
            found.add("agent-watch")
            name = agents.get(payload.get("agentId"))
            if name:
                found.add(f"agent-costs-{name}")
    elif kind == "agent.status":
        found.add("agent-watch")
    return found


def ws_url(base):
    if base.startswith("https://"):
        return "wss://" + base[len("https://"):]
    if base.startswith("http://"):
        return "ws://" + base[len("http://"):]
    return base


def write_json(path, value):
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    tmp.chmod(0o644)
    tmp.replace(path)


class Relay:
    def __init__(self, base, key, events_dir, state_dir, consumers, cost_agents):
        self.base = base.rstrip("/")
        self.key = key
        self.events_dir = pathlib.Path(events_dir)
        self.state_dir = pathlib.Path(state_dir)
        self.cost_agents = {name.lower() for name in cost_agents}
        self.consumers = set(consumers) | {f"agent-costs-{name}" for name in self.cost_agents}
        self.agents = {}
        self.status = {"started": iso(now()), "connected": False, "reconnects": 0, "nudges": {}}
        self.connections = 0

    def save_status(self):
        try:
            write_json(self.state_dir / "status.json", self.status)
        except OSError as err:
            log.warning("can't write status.json: %s", err)

    def problem(self, text):
        log.warning("%s", text)
        self.status.update(last_error=text, last_error_at=iso(now()))
        self.save_status()

    def nudge(self, consumers):
        for consumer in sorted(set(consumers) & self.consumers):
            folder = self.events_dir / f"{consumer}.d"
            try:
                folder.mkdir(exist_ok=True)
                (folder / "pending").write_text(iso(now()) + "\n")
            except OSError as err:
                self.problem(f"can't nudge {consumer}: {err}")
                continue
            self.status["nudges"][consumer] = self.status["nudges"].get(consumer, 0) + 1

    async def get(self, session, path):
        async with session.get(self.base + path, headers={"Authorization": f"Bearer {self.key}"}) as response:
            if response.status != 200:
                raise Failure(f"GET {path} answered {response.status}")
            return await response.json()

    async def connect_once(self, session):
        me = await self.get(session, "/api/agents/me")
        company = me.get("companyId") if isinstance(me, dict) else None
        if not isinstance(company, str) or not company:
            raise Failure("GET /api/agents/me has no companyId")
        listed = await self.get(session, f"/api/companies/{company}/agents")
        self.agents = {a["id"]: a["name"].lower() for a in listed
                       if isinstance(a, dict) and isinstance(a.get("id"), str)
                       and isinstance(a.get("name"), str) and a["name"].lower() in self.cost_agents}
        url = ws_url(self.base) + f"/api/companies/{company}/events/ws"
        async with session.ws_connect(url, headers={"Authorization": f"Bearer {self.key}"}, heartbeat=30) as ws:
            self.connections += 1
            if self.connections > 1:
                self.status["reconnects"] += 1
            self.status.update(connected=True, connected_since=iso(now()), last_ok=iso(now()))
            log.info("connected to %s's live events", company)
            # Whatever happened while we weren't listening.
            self.nudge(self.consumers)
            self.save_status()
            async for message in ws:
                if message.type == aiohttp.WSMsgType.TEXT:
                    try:
                        event = json.loads(message.data)
                    except ValueError:
                        log.warning("an event that isn't JSON, ignored")
                        continue
                    self.nudge(targets(event, self.agents))
                    self.status["last_ok"] = iso(now())
                elif message.type in (aiohttp.WSMsgType.CLOSE, aiohttp.WSMsgType.CLOSED, aiohttp.WSMsgType.ERROR):
                    break
            code = ws.close_code
        return f"Paperclip closed the connection ({code})" if code else "the connection closed"

    async def keep_fresh(self):
        """last_ok stays fresh while connected, so a quiet hour isn't
        mistaken for a dead relay."""
        while True:
            await asyncio.sleep(60)
            if self.status["connected"]:
                self.status["last_ok"] = iso(now())
            self.save_status()

    async def run(self, session_factory=aiohttp.ClientSession):
        attempt = 0
        timeout = aiohttp.ClientTimeout(total=None, connect=15, sock_connect=15)
        async with session_factory(timeout=timeout) as session:
            while True:
                began = asyncio.get_running_loop().time()
                try:
                    reason = await self.connect_once(session)
                except (aiohttp.ClientError, asyncio.TimeoutError, Failure, OSError, ValueError) as err:
                    reason = str(err) or type(err).__name__
                if self.status["connected"]:
                    self.status.update(connected=False, disconnected_at=iso(now()))
                self.problem(f"not connected: {reason}")
                if asyncio.get_running_loop().time() - began >= STEADY:
                    attempt = 0
                await asyncio.sleep(BACKOFF[min(attempt, len(BACKOFF) - 1)])
                attempt += 1


def credential(name):
    return (pathlib.Path(os.environ["CREDENTIALS_DIRECTORY"]) / name).read_text().strip()


async def main():
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s", stream=sys.stdout)
    relay = Relay(
        os.environ.get("PAPERCLIP_URL", "http://127.0.0.1:3100"),
        credential("paperclip-key"),
        os.environ["EVENTS_DIR"],
        os.environ["STATE_DIR"],
        os.environ.get("CONSUMERS", "").split(),
        os.environ.get("COST_AGENTS", "").split(),
    )
    relay.save_status()
    await asyncio.gather(relay.run(), relay.keep_fresh())


if __name__ == "__main__":
    asyncio.run(main())
