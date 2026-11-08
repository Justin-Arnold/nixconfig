#!/usr/bin/env python3
"""Tests paperclip-events.py.

targets() is checked against each kind of event Paperclip 2026.1023.0
sends, odd ones included. Then the relay runs against a fake Paperclip that
answers /api/agents/me and the agent list with the right key only, and
holds the live websocket. The checks:

- a connect nudges every consumer once, the agent-costs ones included;
- each event nudges only the consumers that want it, and only those that
  are on;
- what isn't JSON, and events nobody wants, nudge nothing;
- status.json says connected, with nudge counts, and never holds the key;
- when Paperclip drops the connection, the relay says so, connects again
  and nudges everyone again;
- a wrong key is refused, said so in status.json, and nudges nothing.

usage: test.py <paperclip-events.py>
"""
import asyncio
import importlib.util
import json
import pathlib
import sys
import tempfile

from aiohttp import web

spec = importlib.util.spec_from_file_location("paperclip_events", sys.argv[1])
relay_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay_mod)
# Connect again at once in the tests.
relay_mod.BACKOFF = (0.05,)

KEY = "pcp_" + "ab" * 24
COMPANY = "c0ffee00-0000-4000-8000-000000000001"
INFRA = "a1111111-0000-4000-8000-000000000001"
RESEARCHER = "a2222222-0000-4000-8000-000000000002"
OTHER = "a3333333-0000-4000-8000-000000000003"

checks = 0


def check(condition, what):
    global checks
    checks += 1
    if not condition:
        print(f"FAIL {what}")
        sys.exit(1)
    print(f"ok   {what}")


def activity(action):
    return {"type": "activity.logged", "payload": {"action": action, "entityType": "issue", "entityId": "i1"}}


def run_status(agent, finished):
    return {"type": "heartbeat.run.status",
            "payload": {"runId": "r1", "agentId": agent, "status": "succeeded" if finished else "running",
                        "finishedAt": "2026-11-06T10:00:00Z" if finished else None}}


def test_targets():
    agents = {INFRA: "infra"}
    t = relay_mod.targets
    check(t(activity("issue.thread_interaction_created"), agents) == {"agent-watch", "board-bridge"},
          "a new question nudges agent-watch and the bridge")
    check(t(activity("issue.thread_interaction_answered"), agents) == {"agent-watch", "board-bridge"},
          "an answered question does too")
    check(t(activity("approval.created"), agents) == {"agent-watch", "board-bridge"}, "a new approval does too")
    check(t(activity("approval.approved"), agents) == {"agent-watch", "board-bridge"}, "an approved one does too")
    check(t(activity("issue.updated"), agents) == {"agent-watch"}, "a changed issue nudges agent-watch")
    check(t(activity("issue.created"), agents) == {"agent-watch"}, "so does a new issue")
    check(t(activity("issue.comment_added"), agents) == set(), "a comment nudges nobody")
    check(t(activity("routine.run_triggered"), agents) == set(), "nor does a routine run")
    check(t(run_status(INFRA, True), agents) == {"agent-watch", "agent-costs-infra"},
          "infra's finished run nudges agent-watch and agent-costs-infra")
    check(t(run_status(INFRA, False), agents) == set(), "a run that's still going nudges nobody")
    check(t(run_status(OTHER, True), agents) == {"agent-watch"},
          "a finished run of an agent without agent-costs nudges agent-watch alone")
    check(t({"type": "agent.status", "payload": {"agentId": INFRA, "status": "error"}}, agents) == {"agent-watch"},
          "an agent's status nudges agent-watch")
    check(t({"type": "heartbeat.run.log", "payload": {"runId": "r1"}}, agents) == set(), "a run's log nudges nobody")
    check(t({"type": "plugin.ui.updated", "payload": {}}, agents) == set(), "a plugin event nudges nobody")
    for odd in (None, [], "x", {}, {"type": "activity.logged"}, {"type": "activity.logged", "payload": "x"},
                {"type": "activity.logged", "payload": {"action": 7}}):
        check(t(odd, agents) == set(), f"{json.dumps(odd)} nudges nobody")
    check(relay_mod.ws_url("http://127.0.0.1:3100") == "ws://127.0.0.1:3100", "http becomes ws")
    check(relay_mod.ws_url("https://p.example") == "wss://p.example", "https becomes wss")


class FakePaperclip:
    def __init__(self):
        self.sockets = asyncio.Queue()
        self.app = web.Application()
        self.app.router.add_get("/api/agents/me", self.me)
        self.app.router.add_get(f"/api/companies/{COMPANY}/agents", self.agents)
        self.app.router.add_get(f"/api/companies/{COMPANY}/events/ws", self.ws)

    def authorized(self, request):
        return request.headers.get("Authorization") == f"Bearer {KEY}"

    async def me(self, request):
        if not self.authorized(request):
            return web.json_response({"error": "unauthorized"}, status=401)
        return web.json_response({"id": RESEARCHER, "companyId": COMPANY, "name": "Researcher"})

    async def agents(self, request):
        if not self.authorized(request):
            return web.json_response({"error": "unauthorized"}, status=401)
        return web.json_response([{"id": INFRA, "name": "Infra"}, {"id": RESEARCHER, "name": "Researcher"},
                                  {"id": OTHER, "name": "Other"}, {"id": 7}, "x"])

    async def ws(self, request):
        if not self.authorized(request):
            return web.Response(status=403)
        socket = web.WebSocketResponse()
        await socket.prepare(request)
        closed = asyncio.Event()
        await self.sockets.put((socket, closed))
        await closed.wait()
        await socket.close()
        return socket


async def until(condition, what, seconds=5):
    for _ in range(int(seconds / 0.02)):
        if condition():
            break
        await asyncio.sleep(0.02)
    check(condition(), what)


def pending(events, consumer):
    return (events / f"{consumer}.d" / "pending").exists()


def clear(events):
    for marker in events.glob("*.d/pending"):
        marker.unlink()


async def test_relay():
    fake = FakePaperclip()
    runner = web.AppRunner(fake.app)
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", 0)
    await site.start()
    port = site._server.sockets[0].getsockname()[1]
    base = f"http://127.0.0.1:{port}"

    with tempfile.TemporaryDirectory() as tmp:
        events = pathlib.Path(tmp) / "events"
        state = pathlib.Path(tmp) / "state"
        events.mkdir()
        state.mkdir()
        everyone = {"agent-watch", "board-bridge", "agent-costs-infra", "agent-costs-researcher"}
        relay = relay_mod.Relay(base, KEY, events, state, ["agent-watch", "board-bridge"], ["infra", "Researcher"])
        task = asyncio.create_task(relay.run())

        socket, closed = await asyncio.wait_for(fake.sockets.get(), 5)
        await until(lambda: all(pending(events, c) for c in everyone), "a connect nudges every consumer")
        relay.nudge({"not-on-here"})
        check(not pending(events, "not-on-here"), "a consumer that isn't on isn't nudged")
        check(relay.agents == {INFRA: "infra", RESEARCHER: "researcher"},
              "agents with an agent-costs unit are mapped by name, odd entries skipped")
        status = json.loads((state / "status.json").read_text())
        check(status["connected"] is True and status.get("last_ok"), "status.json says connected")
        check(oct((state / "status.json").stat().st_mode & 0o777) == "0o644", "status.json is readable by agent-watch")

        clear(events)
        await socket.send_str(json.dumps(activity("issue.thread_interaction_created")))
        await until(lambda: pending(events, "agent-watch") and pending(events, "board-bridge"),
                    "a question nudges agent-watch and the bridge")
        check(not pending(events, "agent-costs-infra"), "and not agent-costs")

        clear(events)
        await socket.send_str("not json")
        await socket.send_str(json.dumps(activity("issue.comment_added")))
        await socket.send_str(json.dumps(run_status(INFRA, True)))
        await until(lambda: pending(events, "agent-costs-infra"), "infra's finished run nudges agent-costs-infra")
        check(pending(events, "agent-watch"), "and agent-watch")
        check(not pending(events, "board-bridge") and not pending(events, "agent-costs-researcher"),
              "what isn't JSON and a comment nudge nobody")

        relay.save_status()
        text = (state / "status.json").read_text()
        check(KEY not in text, "status.json never holds the key")
        status = json.loads(text)
        check(status["nudges"]["agent-watch"] == 3 and status["nudges"]["board-bridge"] == 2,
              "status.json counts each consumer's nudges")

        clear(events)
        closed.set()
        socket, closed = await asyncio.wait_for(fake.sockets.get(), 5)
        await until(lambda: all(pending(events, c) for c in everyone), "connecting again nudges everyone again")
        status = json.loads((state / "status.json").read_text())
        check(status["reconnects"] == 1 and "closed" in status.get("last_error", ""),
              "status.json counts the reconnect and says why it dropped")
        await until(lambda: json.loads((state / "status.json").read_text())["connected"] is True,
                    "and says connected again")
        task.cancel()
        closed.set()

    with tempfile.TemporaryDirectory() as tmp:
        events = pathlib.Path(tmp) / "events"
        state = pathlib.Path(tmp) / "state"
        events.mkdir()
        state.mkdir()
        wrong = relay_mod.Relay(base, "pcp_" + "00" * 24, events, state, ["agent-watch"], [])
        task = asyncio.create_task(wrong.run())
        await until(lambda: (state / "status.json").exists()
                    and "401" in json.loads((state / "status.json").read_text()).get("last_error", ""),
                    "a wrong key is refused and status.json says so")
        status = json.loads((state / "status.json").read_text())
        check(status["connected"] is False and not status.get("last_ok"), "and it isn't connected")
        check(not list(events.glob("*.d/pending")), "and nobody is nudged")
        task.cancel()

    await runner.cleanup()


test_targets()
asyncio.run(test_relay())
print(f"{checks} checks passed")
