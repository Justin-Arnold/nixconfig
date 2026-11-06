#!/usr/bin/env python3
"""Runs board-bridge.py's core, its Telegram adapter and its Discord adapter
against fakes.

The fake Paperclip keeps what the bridge relies on from 2026.1023.0: the
company list, agents, open issues and their interactions, pending
approvals, and the respond, accept, reject, approve and reject calls, and
it fails any call outside the bridge's ROUTES. The fake Telegram API keeps
sendMessage, editMessageText, answerCallbackQuery and getUpdates' shape.
Discord's side uses discord.py's own views and items with fake presses.

The tests check what goes out and once only, what each kind of item looks
like, every kind of answer, toggles, text answers, answers given in
Paperclip, items that are cancelled, that only Justin's presses in a DM
count, that a failed read finishes nothing, that a restart doesn't send
again, and that no key or token is ever in an error.

usage: test.py <board-bridge.py>
"""
import asyncio
import copy
import importlib.util
import json
import logging
import pathlib
import sys
import tempfile
import threading
import types
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

spec = importlib.util.spec_from_file_location("board_bridge", sys.argv[1])
bb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bb)
logging.basicConfig(level=logging.CRITICAL)

COMPANY = "22222222-2222-4222-8222-222222222222"
RESEARCHER = "33333333-3333-4333-8333-333333333333"
JUSTIN_TG, JUSTIN_DC = 1111, 222222222222222222
failures = []


def check(what, ok):
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        failures.append(what)


def uid(n):
    return f"{n:08x}-0000-4000-8000-000000000000"


class FakePaperclip:
    def __init__(self):
        self.issues = {}
        self.interactions = {}
        self.approvals = {}
        self.calls = []
        self.down = False

    def issue(self, n, status="blocked"):
        self.issues[uid(n)] = {"id": uid(n), "identifier": f"LAB-{n}", "title": f"Issue {n}", "status": status,
                               "assigneeAgentId": RESEARCHER}
        return uid(n)

    def ask(self, n, issue, kind, payload, **extra):
        self.interactions[uid(n)] = {"id": uid(n), "issueId": issue, "kind": kind, "status": "pending",
                                     "createdAt": f"2026-11-05T00:00:{n % 60:02d}Z", "createdByAgentId": RESEARCHER,
                                     "payload": payload, "result": None, **extra}
        return uid(n)

    def call(self, method, path, body=None):
        self.calls.append((method, path, copy.deepcopy(body)))
        if not bb.allowed(method, path):
            raise AssertionError(f"the bridge called {method} {path}, which isn't in ROUTES")
        if self.down:
            raise bb.Failure(f"{method} {path.split('?')[0]}: can't reach Paperclip: refused")
        route, _, query = path.partition("?")
        parts = route.strip("/").split("/")
        if route == "/api/companies":
            return [{"id": uid(99), "issuePrefix": "OTHER"}, {"id": COMPANY, "issuePrefix": "LAB"}]
        if route == f"/api/companies/{COMPANY}/agents":
            return [{"id": RESEARCHER, "name": "Researcher"}]
        if route == f"/api/companies/{COMPANY}/issues":
            statuses = dict(p.split("=") for p in query.split("&"))["status"].split(",")
            return [i for i in self.issues.values() if i["status"] in statuses]
        if route == f"/api/companies/{COMPANY}/approvals":
            assert query == "status=pending", query
            return [a for a in self.approvals.values() if a["status"] == "pending"]
        if parts[:2] == ["api", "approvals"]:
            approval = self.approvals.get(parts[2])
            if approval is None:
                raise bb.Failure(f"GET /api/approvals/{parts[2]}: HTTP 404 Approval not found")
            if len(parts) == 3:
                return approval
            if approval["status"] != "pending":
                raise bb.Failure(f"POST {route}: HTTP 422 Only pending approvals can be decided")
            approval.update(status="approved" if parts[3] == "approve" else "rejected",
                            decisionNote=(body or {}).get("decisionNote"))
            return approval
        if parts[:2] == ["api", "issues"] and parts[3] == "interactions":
            if len(parts) == 4:
                return [i for i in self.interactions.values() if i["issueId"] == parts[2]]
            interaction = self.interactions[parts[4]]
            if interaction["status"] != "pending":
                raise bb.Failure(f"POST {route}: HTTP 409 Interaction is not pending")
            action = parts[5]
            if action == "respond":
                interaction.update(status="answered", result={"version": 1, "answers": body["answers"]})
            elif action == "accept":
                interaction.update(status="accepted", result={"version": 1, "outcome": "accepted", **body})
            else:
                interaction.update(status="rejected", result={"version": 1, "outcome": "rejected", "reason": body.get("reason")})
            return interaction
        raise AssertionError(f"the fake has no {method} {path}")


class FakeChannel:
    def __init__(self, name):
        self.name = name
        self.sent, self.edits = [], []
        self.down = None

    async def send(self, card):
        self.sent.append(card)
        return [1, len(self.sent)]

    async def edit(self, ref, card):
        self.edits.append((ref, card))

    def trouble(self):
        return self.down


def question(prompt="Which tree?", mode="single", options=("pine (recommended)", "oak"), **extra):
    return {"version": 1, "title": prompt, "questions": [{
        "id": "q1", "prompt": prompt, "selectionMode": mode,
        "options": [{"id": f"o{n}", "label": label, "description": f"trade-off {n}"} for n, label in enumerate(options)],
        **extra}]}


def run(coro):
    return asyncio.run(coro)


def latest(channel, token):
    edits = [card for _, card in channel.edits if card["token"] == token]
    return edits[-1] if edits else None


def actions(card):
    return [action for row in card["rows"] for _, action in row]


async def core_tests(tmp):
    pc = FakePaperclip()
    a, b = pc.issue(5), pc.issue(6, status="in_progress")
    single = pc.ask(1, a, "ask_user_questions", question())
    multi = pc.ask(2, b, "ask_user_questions", question("Which ones?", "multi", ("red", "green", "blue"), allowOther=True))
    confirm = pc.ask(3, b, "request_confirmation", {"version": 1, "prompt": "Restart the gateway?", "detailsMarkdown": "**bold** stays plain"})
    form = pc.ask(4, b, "ask_user_questions", {"version": 1, "questions": [question()["questions"][0], {**question()["questions"][0], "id": "q2"}]})
    checkbox = pc.ask(5, b, "request_checkbox_confirmation", {
        "version": 1, "prompt": "Which hosts?", "options": [{"id": "h1", "label": "agents"}, {"id": "h2", "label": "workbench"}],
        "defaultSelectedOptionIds": ["h1"], "minSelected": 1, "maxSelected": 1})
    agent_only = pc.ask(6, b, "ask_user_questions", question("For the coordinator"), addresseeAgentId=uid(77))
    done_one = pc.ask(7, b, "ask_user_questions", question())
    pc.interactions[done_one]["status"] = "answered"
    tool = pc.ask(8, b, "request_confirmation", {"version": 1, "prompt": "Run a tool?", "toolAction": {"toolName": "x"}})
    pc.approvals[uid(50)] = {"id": uid(50), "type": "request_board_approval", "status": "pending", "createdAt": "2026-11-05T00:01:00Z",
                             "requestedByAgentId": RESEARCHER,
                             "payload": {"title": "Open port 443", "summary": "For the dashboard", "risks": ["exposure"]}}

    tg, dc = FakeChannel("Telegram"), FakeChannel("Discord")
    bridge = bb.Bridge(pc, tmp, "https://paperclip.example/LAB")
    bridge.channels = [tg, dc]
    await bridge.pass_once()
    keys = {f"i:{single}", f"i:{multi}", f"i:{confirm}", f"i:{form}", f"i:{checkbox}", f"i:{tool}", f"a:{uid(50)}"}
    check("the first pass sends every pending item for the board to both channels, oldest first",
          len(tg.sent) == len(keys) == len(dc.sent) and tg.sent[0]["token"] == bb.token_of(f"i:{single}")
          and set(bridge.state["items"]) == keys)
    check("an interaction addressed to an agent and an answered one aren't sent",
          f"i:{agent_only}" not in bridge.state["items"] and f"i:{done_one}" not in bridge.state["items"])
    await bridge.pass_once()
    check("the next pass sends nothing again", len(tg.sent) == len(keys) and len(dc.sent) == len(keys))

    status = json.loads((pathlib.Path(tmp) / "status.json").read_text())
    check("status.json says the pass worked and where each waiting item went",
          status.get("last_ok") and not status.get("last_error")
          and all(w["sent"] == ["Discord", "Telegram"] for w in status["waiting"]) and len(status["waiting"]) == len(keys))
    check("status.json says when each was asked and when it reached each channel",
          all(w["created"] and sorted(w["sent_at"]) == ["Discord", "Telegram"]
              and all(bb.iso(bb.now())[:10] in at for at in w["sent_at"].values()) for w in status["waiting"]))

    cards = {card["token"]: card for card in tg.sent}
    card = cards[bb.token_of(f"i:{single}")]
    check("a single-choice question has the issue, the agent, the options and their trade-offs, and a button each",
          card["text"].startswith("LAB-5 · Researcher asks") and "1. pine (recommended): trade-off 0" in card["text"]
          and actions(card) == ["o0", "o1"] and card["url"] == "https://paperclip.example/LAB/issues/LAB-5")
    check("Markdown in a confirmation stays plain text",
          "**bold** stays plain" in cards[bb.token_of(f"i:{confirm}")]["text"]
          and actions(cards[bb.token_of(f"i:{confirm}")]) == ["ok", "no", "xno"])
    check("a form with two questions and a tool action get the link and no buttons",
          actions(cards[bb.token_of(f"i:{form}")]) == [] and "Answer this one in Paperclip." in cards[bb.token_of(f"i:{form}")]["text"]
          and actions(cards[bb.token_of(f"i:{tool}")]) == [])
    approval = cards[bb.token_of(f"a:{uid(50)}")]
    check("an approval shows its type, title, summary and risks, links to itself, and approves in one tap",
          "Board approval" in approval["text"] and "Open port 443" in approval["text"] and "- exposure" in approval["text"]
          and approval["url"] == f"https://paperclip.example/LAB/approvals/{uid(50)}" and actions(approval)[:2] == ["ok", "no"])
    check("a checkbox confirmation starts with its defaults ticked",
          cards[bb.token_of(f"i:{checkbox}")]["rows"][0][0][0].startswith("☑"))

    # Answering.
    ok, notice = await bridge.press("Telegram", bb.token_of(f"i:{single}"), "o1")
    check("picking an option answers the question with it in Paperclip",
          ok and pc.interactions[single]["result"]["answers"] == [{"questionId": "q1", "optionIds": ["o1"]}] and notice == "Sent: oak")
    done = latest(dc, bb.token_of(f"i:{single}"))
    check("every copy says where and what, and loses its buttons",
          done and done["status"] == "✓ Answered in Telegram: oak" and done["rows"] == []
          and latest(tg, bb.token_of(f"i:{single}"))["status"] == done["status"])
    ok, notice = await bridge.press("Discord", bb.token_of(f"i:{single}"), "o0")
    check("a second press on an answered item does nothing", not ok and notice == "Already answered."
          and pc.interactions[single]["result"]["answers"][0]["optionIds"] == ["o1"])

    token = bb.token_of(f"i:{multi}")
    ok, notice = await bridge.press("Discord", token, "s")
    check("submitting a multiple choice with nothing picked asks for a pick", not ok and "at least one" in notice)
    await bridge.press("Discord", token, "t0")
    await bridge.press("Telegram", token, "t2")
    card = latest(tg, token)
    check("toggles show on every copy", card["rows"][0][0][0].startswith("☑") and card["rows"][2][0][0].startswith("☑")
          and latest(dc, token)["rows"][1][0][0].startswith("☐"))
    await bridge.press("Discord", token, "t2")
    ok, _ = await bridge.press("Discord", token, "xa", "teal")
    check("Other sends what's picked and the text",
          ok and pc.interactions[multi]["result"]["answers"] == [{"questionId": "q1", "optionIds": ["o0"], "otherText": "teal"}]
          and latest(tg, token)["status"] == "✓ Answered in Discord: red, teal")

    token = bb.token_of(f"i:{checkbox}")
    await bridge.press("Telegram", token, "t1")
    ok, notice = await bridge.press("Telegram", token, "ok")
    check("a checkbox confirmation keeps to its limits", not ok and notice == "Pick at most 1.")
    await bridge.press("Telegram", token, "t0")
    ok, _ = await bridge.press("Telegram", token, "ok")
    check("accepting a checkbox confirmation sends what's ticked",
          ok and pc.interactions[checkbox]["status"] == "accepted" and pc.interactions[checkbox]["result"]["selectedOptionIds"] == ["h2"])

    ok, notice = await bridge.press("Telegram", bb.token_of(f"i:{confirm}"), "xno", "  ")
    check("a reason that's blank doesn't go", not ok and pc.interactions[confirm]["status"] == "pending")
    ok, _ = await bridge.press("Telegram", bb.token_of(f"i:{confirm}"), "xno", "not now")
    check("rejecting with a reason sends it", ok and pc.interactions[confirm]["result"]["reason"] == "not now")

    ok, _ = await bridge.press("Discord", bb.token_of(f"a:{uid(50)}"), "ok")
    check("an approval approves in one tap", ok and pc.approvals[uid(50)]["status"] == "approved")
    ok, notice = await bridge.press("Discord", bb.token_of(f"i:{form}"), "o0")
    check("a press can't answer what only Paperclip can", not ok and pc.interactions[form]["status"] == "pending")
    ok, notice = await bridge.press("Discord", "deadbeef", "ok")
    check("a press for something unknown is refused", not ok)

    # Answered elsewhere, cancelled, and gone.
    pc.interactions[form].update(status="answered", result={"version": 1, "answers": [
        {"questionId": "q1", "optionIds": ["o0"]}, {"questionId": "q2", "optionIds": [], "otherText": "maple"}]})
    pc.interactions[tool].update(status="cancelled")
    answered = dict(status["answered"])
    before = len(tg.edits)
    await bridge.pass_once()
    check("an answer given in Paperclip shows on every copy and counts as Paperclip's",
          latest(tg, bb.token_of(f"i:{form}"))["status"] == "✓ Answered in Paperclip: pine (recommended), maple"
          and latest(dc, bb.token_of(f"i:{form}")) is not None)
    check("a cancelled one says it's no longer waiting",
          latest(tg, bb.token_of(f"i:{tool}"))["status"] == "No longer waiting: cancelled.")
    check("what the bridge answered itself isn't edited again", len(tg.edits) == before + 2)
    status = json.loads((pathlib.Path(tmp) / "status.json").read_text())
    check("status.json counts answers by channel and keeps what finished",
          status["answered"] == {"Telegram": 3, "Discord": 2, "Paperclip": 1} and answered == {}
          and status["waiting"] == [] and {r["via"] for r in status["recent"]} == {"Telegram", "Discord", "Paperclip", None})
    check("nothing is left in state.json", json.loads((pathlib.Path(tmp) / "state.json").read_text())["items"] == {})

    # A failed read finishes nothing; a restart doesn't resend.
    late = pc.ask(9, a, "request_confirmation", {"version": 1, "prompt": "Late?"})
    await bridge.pass_once()
    pc.down = True
    await bridge.pass_once()
    status = json.loads((pathlib.Path(tmp) / "status.json").read_text())
    check("a pass that can't read Paperclip says so and keeps what's waiting",
          "can't reach Paperclip" in status["last_error"] and f"i:{late}" in bridge.state["items"])
    pc.down = False
    again = bb.Bridge(pc, tmp, "https://paperclip.example/LAB")
    tg2, dc2 = FakeChannel("Telegram"), FakeChannel("Discord")
    again.channels = [tg2, dc2]
    await again.pass_once()
    check("after a restart, nothing already sent goes again", tg2.sent == [] and dc2.sent == [])
    dc2.down = "not connected to Discord"
    pc.ask(10, a, "request_confirmation", {"version": 1, "prompt": "While Discord's down?"})
    await again.pass_once()
    status = json.loads((pathlib.Path(tmp) / "status.json").read_text())
    check("a channel that's down is skipped and named, and gets the item once it's back",
          len(tg2.sent) == 1 and dc2.sent == [] and "Discord: not connected" in status["last_error"])
    dc2.down = None
    await again.pass_once()
    check("…and then it goes", len(dc2.sent) == 1)

    check("every call the bridge made is in ROUTES", all(bb.allowed(m, p) for m, p, _ in pc.calls))
    for method, path in [("POST", f"/api/issues/{a}/comments"), ("PATCH", f"/api/issues/{a}"), ("POST", "/api/board-api-keys"),
                         ("DELETE", f"/api/approvals/{uid(50)}"), ("POST", f"/api/issues/{a}/interactions/{single}/cancel"),
                         ("GET", "/api/companies/x/agents"), ("POST", f"/api/approvals/{uid(50)}/approve/../../x")]:
        check(f"ROUTES refuses {method} {path}", not bb.allowed(method, path))


class FakeTelegramApi:
    def __init__(self):
        self.calls = []
        self.next_id = 100

    def __call__(self, method, params, timeout=30):
        self.calls.append((method, copy.deepcopy(params)))
        if method == "sendMessage":
            self.next_id += 1
            return {"message_id": self.next_id, "chat": {"id": params["chat_id"], "type": "private"}}
        return True

    def called(self, method):
        return [p for m, p in self.calls if m == method]


async def telegram_tests(tmp):
    pc = FakePaperclip()
    a = pc.issue(5)
    confirm = pc.ask(1, a, "request_confirmation", {"version": 1, "prompt": "Restart?"})
    api = FakeTelegramApi()
    bridge = bb.Bridge(pc, tmp, "https://paperclip.example/LAB")
    tg = bb.Telegram(api, str(JUSTIN_TG), bridge)
    bridge.channels = [tg]
    await bridge.pass_once()
    sent = api.called("sendMessage")[0]
    buttons = [b for row in sent["reply_markup"]["inline_keyboard"] for b in row]
    check("Telegram gets a DM to Justin, as plain text, with buttons and the link",
          sent["chat_id"] == JUSTIN_TG and "parse_mode" not in sent and buttons[-1] == {
              "text": "Open in Paperclip", "url": "https://paperclip.example/LAB/issues/LAB-5"}
          and all(len(b["callback_data"].encode()) <= 64 for b in buttons if "callback_data" in b))
    token = bb.token_of(f"i:{confirm}")

    def press(sender, data, chat="private"):
        return {"update_id": 1, "callback_query": {"id": "cq", "from": {"id": sender}, "data": data,
                                                   "message": {"message_id": 101, "chat": {"id": sender, "type": chat}}}}

    await tg.handle(press(999, f"{token}:ok"))
    await tg.handle(press(JUSTIN_TG, f"{token}:ok", chat="group"))
    check("a press from anyone else, or from Justin outside a DM, does nothing",
          pc.interactions[confirm]["status"] == "pending" and not api.called("answerCallbackQuery"))
    await tg.handle({"update_id": 2, "message": {"message_id": 5, "from": {"id": 999}, "chat": {"id": 999, "type": "private"}, "text": "hi"}})
    check("a message from anyone else gets no answer", len(api.called("sendMessage")) == 1)

    await tg.handle(press(JUSTIN_TG, f"{token}:xno"))
    prompt = api.called("sendMessage")[-1]
    check("a press that needs text asks for a reply", prompt["reply_markup"] == {"force_reply": True} and "reject" in prompt["text"])
    prompt_id = api.next_id
    await tg.handle({"update_id": 3, "message": {"message_id": 6, "from": {"id": JUSTIN_TG}, "chat": {"id": JUSTIN_TG, "type": "private"},
                                                 "text": "too risky", "reply_to_message": {"message_id": prompt_id}}})
    check("the reply rejects with that reason and the copy is edited",
          pc.interactions[confirm]["result"]["reason"] == "too risky"
          and api.called("editMessageText")[-1]["text"].endswith("✓ Answered in Telegram: Rejected: too risky")
          and api.called("editMessageText")[-1]["reply_markup"]["inline_keyboard"] == [[{"text": "Open in Paperclip", "url": "https://paperclip.example/LAB/issues/LAB-5"}]])

    second = pc.ask(2, a, "ask_user_questions", question())
    await bridge.pass_once()
    await tg.handle(press(JUSTIN_TG, f"{bb.token_of(f'i:{second}')}:o0"))
    check("a tap answers and Telegram says what was sent",
          pc.interactions[second]["status"] == "answered" and api.called("answerCallbackQuery")[-1]["text"] == "Sent: pine (recommended)")

    # The real API client against a fake Telegram: errors never carry the token.
    secret = "123456:" + "Zz" * 17

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):  # noqa: N802
            self.rfile.read(int(self.headers.get("Content-Length") or 0))
            body = json.dumps({"ok": False, "error_code": 401, "description": f"Unauthorized for {self.path}"}).encode()
            self.send_response(401)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        bb.TelegramApi(secret, f"http://127.0.0.1:{server.server_port}")("getMe", {})
        check("a refused Telegram call raises", False)
    except bb.Failure as err:
        check("a refused Telegram call doesn't carry the token", secret not in str(err) and "Unauthorized" in str(err))
    try:
        bb.TelegramApi(secret, "http://127.0.0.1:1")("getMe", {})
    except bb.Failure as err:
        check("an unreachable Telegram doesn't carry the token", secret not in str(err))
    server.shutdown()


class Response:
    def __init__(self):
        self.deferred, self.modal = False, None

    async def defer(self):
        self.deferred = True

    async def send_modal(self, modal):
        self.modal = modal


class Followup:
    def __init__(self):
        self.sent = []

    async def send(self, text):
        self.sent.append(text)


def interaction(user, guild=None):
    return types.SimpleNamespace(user=types.SimpleNamespace(id=user), guild_id=guild, response=Response(), followup=Followup())


async def discord_tests(tmp):
    import discord

    pc = FakePaperclip()
    a = pc.issue(5)
    many = pc.ask(1, a, "ask_user_questions", question("Which?", "multi", [f"opt {n}" for n in range(20)]))
    single = pc.ask(2, a, "ask_user_questions", question())
    bridge = bb.Bridge(pc, tmp, "https://paperclip.example/LAB")
    channel = bb.discord_channel("unused-token", str(JUSTIN_DC), bridge)
    await bridge.pass_once()  # no channel registered yet: this only fills state

    for key in (f"i:{many}", f"i:{single}", ):
        card = bridge.card(bridge.state["items"][key])
        view = channel.view(card)
        rows = {}
        for item in view.children:
            rows.setdefault(item.row, []).append(item)
        presses = [i for i in view.children if getattr(i, "custom_id", None)]
        link = [i for i in view.children if getattr(i, "url", None)]
        check(f"Discord's view for {len(bb.options_of(bridge.state['items'][key]['item']))} options fits five rows of five, with the link",
              max(rows) <= 4 and all(len(r) <= 5 for r in rows.values()) and len(link) == 1
              and link[0].url == "https://paperclip.example/LAB/issues/LAB-5"
              and all(i.custom_id.startswith(f"bb:{card['token']}:") and len(i.custom_id) <= 100 and len(i.item.label) <= 80 for i in presses))

    token = bb.token_of(f"i:{single}")
    for who, guild in ((123, None), (JUSTIN_DC, 456)):
        press = interaction(who, guild)
        await channel.pressed(press, token, "o1")
        check(f"a Discord press from {'someone else' if who == 123 else 'Justin in a server'} does nothing",
              not press.response.deferred and pc.interactions[single]["status"] == "pending")
    press = interaction(JUSTIN_DC)
    await channel.pressed(press, token, "xa")
    check("a press that needs text opens a form", isinstance(press.response.modal, discord.ui.Modal) and not press.response.deferred)
    press = interaction(JUSTIN_DC)
    await channel.pressed(press, token, "o1")
    check("Justin's press in a DM answers, and only a problem gets a reply",
          press.response.deferred and pc.interactions[single]["result"]["answers"][0]["optionIds"] == ["o1"] and press.followup.sent == [])
    press = interaction(JUSTIN_DC)
    await channel.pressed(press, token, "o0")
    check("a press on an answered item says so", press.followup.sent == ["Already answered."])
    match = type(channel.view(bridge.card(bridge.state["items"][f"i:{many}"])).children[0]).__discord_ui_compiled_template__
    check("every action fits the button template", all(match.fullmatch(f"bb:{token}:{action}")
                                                       for action in ("o19", "t19", "xo19", "xa", "s", "ok", "no", "xno")))
    bridge.wake.clear()
    await channel.client.on_ready()
    check("Discord connecting nudges the bridge, so what waited for it goes out", bridge.wake.is_set())


async def nudge_tests(tmp):
    """A nudge (paperclip-events' SIGHUP) starts a pass at once, and one
    during a pass makes exactly one more."""
    bridge = bb.Bridge(FakePaperclip(), tmp, poll=60)
    passes = []
    gate = asyncio.Event()

    async def counted():
        passes.append(len(passes))
        if len(passes) == 2:
            await gate.wait()

    bridge.pass_once = counted
    task = asyncio.create_task(bridge.run())
    for _ in range(50):
        await asyncio.sleep(0.01)
    check("it reads once as it starts, then waits for the poll", passes == [0])
    bridge.nudge()
    for _ in range(50):
        await asyncio.sleep(0.01)
    check("a nudge reads at once, not at the next poll", len(passes) == 2)
    bridge.nudge()
    bridge.nudge()
    gate.set()
    for _ in range(50):
        await asyncio.sleep(0.01)
    check("nudges during a pass make exactly one more", len(passes) == 3)
    task.cancel()

    # A pass that went wrong, like one before Discord connected, tries again
    # after the retry, not the poll; a clean one waits for the poll again.
    bridge = bb.Bridge(FakePaperclip(), tmp, poll=60, retry=0.3)
    passes = []

    async def troubled():
        passes.append(len(passes))
        bridge.errors = ["Discord: not connected to Discord"] if len(passes) == 1 else []

    bridge.pass_once = troubled
    task = asyncio.create_task(bridge.run())
    await asyncio.sleep(0.7)
    check("a pass that went wrong tries again after the retry, and a clean one waits for the poll", passes == [0, 1])
    task.cancel()

    async def broken():
        passes.append(len(passes))
        raise RuntimeError("boom")

    passes = []
    bridge.pass_once = broken
    task = asyncio.create_task(bridge.run())
    await asyncio.sleep(0.45)
    check("a pass that raised tries again after the retry", len(passes) == 2)
    task.cancel()


def main():
    with tempfile.TemporaryDirectory() as tmp:
        run(core_tests(tmp))
    with tempfile.TemporaryDirectory() as tmp:
        run(nudge_tests(tmp))
    with tempfile.TemporaryDirectory() as tmp:
        run(telegram_tests(tmp))
    try:
        import discord  # noqa: F401
    except ImportError:
        print("skip the Discord tests: discord.py isn't installed here")
    else:
        with tempfile.TemporaryDirectory() as tmp:
            run(discord_tests(tmp))
    if failures:
        sys.exit(f"{len(failures)} failed")
    print("all passed")


if __name__ == "__main__":
    main()
