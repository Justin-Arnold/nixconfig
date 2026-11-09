#!/usr/bin/env python3
"""board-bridge: what waits on the board in Paperclip, as Telegram and
Discord DMs that Justin answers with a tap.

A long-running service on the agents host (hosts/agents/board-bridge.nix).
It reads, with a board key, whenever paperclip-events sends it SIGHUP
because something changed in Paperclip, when Discord connects, every
POLL_SECONDS anyway, and 20 seconds after a pass that went wrong:

- the pending interactions on open issues that aren't addressed to an
  agent: questions, confirmations and checkbox confirmations; and
- the pending approvals.

Each new one goes to every channel that's on, as a DM with buttons and a
link to it in Paperclip. A question with one question, single or multiple
choice, a confirmation, a checkbox confirmation and every approval get
buttons. So does a card with two to MAX_QUESTIONS questions, a row of
buttons each: presses there only mark a pick, and Submit sends every
answer at once. Anything else, like a card with more questions or a tool
action to confirm, gets the link alone. A press answers in Paperclip as
Justin, the same as the board's own buttons, so an agent that asked with
wake_assignee wakes. Text, like an "Other" answer or a reason to reject,
comes as a reply in Telegram and a form in Discord.

Only presses and replies from TELEGRAM_USER and DISCORD_USER in a DM count.
Everything else is logged and ignored. Agents write the question text, so
it goes out as plain text, never parsed as Markdown, and trimmed.

When an item is answered anywhere, every copy is edited to say where and
what, and its buttons go. STATE_DIR/state.json keeps what was sent where,
so a restart doesn't send twice. STATE_DIR/status.json says when a pass
last worked, what last went wrong, what's waiting and where it went, and
how many answers came from each channel, for agent-watch's BridgeStale and
for comparing the channels. Neither holds a secret.

The board key can do anything the board can, so the code calls only the
routes in ROUTES and refuses any other.

Environment: PAPERCLIP_URL, PAPERCLIP_LINK (https://<host>/LAB),
COMPANY_PREFIX, STATE_DIR, POLL_SECONDS (20), TELEGRAM_USER and
DISCORD_USER (a channel is on when its user is set), and
CREDENTIALS_DIRECTORY holding paperclip-key, and telegram-token and
discord-token for the channels that are on.
"""
import asyncio
import datetime
import hashlib
import json
import logging
import os
import pathlib
import re
import signal
import sys
import urllib.error
import urllib.request

log = logging.getLogger("board-bridge")

ID = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
# Every call the bridge makes. The board key can do far more.
ROUTES = [
    ("GET", "/api/companies"),
    ("GET", "/api/companies/{id}/agents"),
    ("GET", "/api/companies/{id}/issues"),
    ("GET", "/api/companies/{id}/approvals"),
    ("GET", "/api/issues/{id}/interactions"),
    ("GET", "/api/approvals/{id}"),
    ("POST", "/api/issues/{id}/interactions/{id}/respond"),
    ("POST", "/api/issues/{id}/interactions/{id}/accept"),
    ("POST", "/api/issues/{id}/interactions/{id}/reject"),
    ("POST", "/api/approvals/{id}/approve"),
    ("POST", "/api/approvals/{id}/reject"),
]
_ROUTES = [(method, re.compile(re.escape(path).replace(re.escape("{id}"), ID) + "$")) for method, path in ROUTES]
# Issues where a question can wait. Done and cancelled ones close theirs.
OPEN_ISSUE = "backlog,todo,in_progress,in_review,blocked"
APPROVAL_TYPES = {
    "hire_agent": "Hire an agent",
    "approve_ceo_strategy": "Strategy",
    "budget_override_required": "Budget override",
    "request_board_approval": "Board approval",
}
ANSWERED = {"answered", "accepted", "rejected", "approved"}
MAX_OPTIONS = 20
# A card of several questions gives each a Discord row of five buttons, its
# options and "Other…", and Submit takes the fifth row.
MAX_QUESTIONS = 4
ROW = 5


class Failure(Exception):
    """Paperclip or a channel didn't do what was asked. The message never
    holds a key or a token."""


def now():
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)


def iso(moment):
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def trim(text, limit):
    text = str(text or "").strip()
    return text if len(text) <= limit else text[: limit - 1] + "…"


def line(text, limit):
    return trim(" ".join(str(text or "").split()), limit)


def allowed(method, path):
    path = path.split("?")[0]
    return any(method == m and pattern.match(path) for m, pattern in _ROUTES)


def write_json(path, value, mode=0o600):
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(value, indent=1, sort_keys=True))
    tmp.chmod(mode)
    tmp.replace(path)


class Paperclip:
    def __init__(self, base, key):
        self.base = base.rstrip("/")
        self.key = key

    def call(self, method, path, body=None):
        if not allowed(method, path):
            raise Failure(f"{method} {path.split('?')[0]} isn't a call the bridge makes")
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(self.base + path, data=data, method=method, headers={
            "Accept": "application/json", "Authorization": f"Bearer {self.key}",
            **({"Content-Type": "application/json"} if data is not None else {})})
        where = f"{method} {path.split('?')[0]}"
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as err:
            raw = err.read(2000).decode(errors="replace")
            try:
                detail = json.loads(raw).get("error") or raw
            except (ValueError, AttributeError):
                detail = raw
            raise Failure(f"{where}: HTTP {err.code} {line(detail, 200).replace(self.key, '<key>')}") from None
        except (urllib.error.URLError, OSError) as err:
            raise Failure(f"{where}: can't reach Paperclip: {getattr(err, 'reason', err)}") from None
        try:
            return json.loads(raw) if raw else None
        except ValueError:
            raise Failure(f"{where} answered with something that isn't JSON") from None


# What an item looks like on a phone.

def options_of(item):
    payload = item["payload"]
    if item["kind"] == "ask_user_questions":
        return payload["questions"][0].get("options") or []
    return payload.get("options") or []


def questions_of(item):
    return (item.get("payload") or {}).get("questions") or []


def form(item):
    """A card of several questions, answered all at once with Submit."""
    return item.get("type") == "interaction" and item["kind"] == "ask_user_questions" and len(questions_of(item)) > 1


def fits_a_row(question):
    options = question.get("options") or []
    return (question.get("selectionMode") in ("single", "multi") and question.get("id")
            and 1 <= len(options) <= ROW - (1 if question.get("allowOther") else 0))


def supported(item):
    """Whether buttons can answer it. Everything else gets the link."""
    payload = item.get("payload") or {}
    kind = item["kind"]
    if item["type"] == "approval":
        return True
    if kind == "ask_user_questions":
        questions = payload.get("questions") or []
        if len(questions) == 1:
            return (questions[0].get("selectionMode") in ("single", "multi")
                    and 1 <= len(questions[0].get("options") or []) <= MAX_OPTIONS)
        return (2 <= len(questions) <= MAX_QUESTIONS and all(fits_a_row(q) for q in questions)
                and len({q["id"] for q in questions}) == len(questions))
    if kind == "request_confirmation":
        return not payload.get("toolAction") and not payload.get("secretProposal")
    if kind == "request_checkbox_confirmation":
        return 1 <= len(payload.get("options") or []) <= MAX_OPTIONS
    return False


def multi(item):
    if item["kind"] == "request_checkbox_confirmation":
        return True
    return item["kind"] == "ask_user_questions" and item["payload"]["questions"][0].get("selectionMode") == "multi"


def default_selection(item):
    if item["type"] == "interaction" and item["kind"] == "request_checkbox_confirmation" and supported(item):
        return list(item["payload"].get("defaultSelectedOptionIds") or [])
    return []


def form_question(item, action):
    """The question (index, question) and, for an option press, the option
    (index, option) that a form action names: q<i>o<n> picks option n of
    question i, xq<i>o<n> picks a free-text option with its text, and xq<i>
    is question i's "Other…". Raises ValueError when it names nothing."""
    match = re.fullmatch(r"x?q(\d)(?:o(\d{1,2}))?", action)
    questions = questions_of(item)
    try:
        qi = int(match[1])
        question = questions[qi]
        if match[2] is None:
            if not question.get("allowOther"):
                raise IndexError
            return qi, question, None, None
        n = int(match[2])
        return qi, question, n, (question.get("options") or [])[n]
    except (TypeError, IndexError):
        raise ValueError("That option isn't on this question any more.") from None


def form_picks(item, picks, texts):
    """[(question number, labels picked, text)] for each question of a form
    with something picked, in order."""
    out = []
    for qi, question in enumerate(questions_of(item)):
        labels = {o.get("id"): line(o.get("label"), 80) for o in question.get("options") or []}
        ids = [i for i in (picks.get(question.get("id")) or []) if i in labels]
        text = (texts.get(question.get("id")) or "").strip()
        if ids or text:
            out.append((qi + 1, [labels[i] for i in ids], text))
    return out


def picks_line(picked):
    return "; ".join(f"{n}. " + ", ".join(labels + ([line(text, 100)] if text else [])) for n, labels, text in picked)


def approval_lines(kind, payload):
    def get(*keys):
        for key in keys:
            value = payload.get(key)
            if value not in (None, "", [], {}):
                return value if isinstance(value, str) else json.dumps(value)
        return None

    lines = []
    if kind == "hire_agent":
        lines.append(f"Hire {get('name') or 'an agent'}" + (f" as {get('role')}" if get("role") else ""))
        for label, key in (("Title", "title"), ("Can", "capabilities"), ("Runs on", "adapterType")):
            if get(key):
                lines.append(f"{label}: {get(key)}")
    elif kind == "approve_ceo_strategy":
        lines += [v for v in (get("title"), get("plan", "description", "strategy", "text")) if v]
    elif kind == "budget_override_required":
        def cents(key):
            value = payload.get(key)
            return f"${value / 100:,.2f}" if isinstance(value, (int, float)) else "?"
        lines.append(f"{get('scopeName', 'scopeType') or 'A'} budget, {get('metric') or 'spend'}"
                     + (f" per {get('windowKind')}" if get("windowKind") else "")
                     + f": limit {cents('budgetAmount')}, observed {cents('observedAmount')}")
        if get("guidance"):
            lines.append(get("guidance"))
    else:
        lines += [v for v in (get("title"), get("summary")) if v]
        if get("recommendedAction"):
            lines.append(f"Recommended: {get('recommendedAction')}")
        if get("nextActionOnApproval"):
            lines.append(f"If you approve: {get('nextActionOnApproval')}")
        risks = payload.get("risks")
        if isinstance(risks, list) and risks:
            lines.append("Risks:")
            for risk in risks[:8]:
                text = risk if isinstance(risk, str) else (risk.get("title") or risk.get("description") or json.dumps(risk)) \
                    if isinstance(risk, dict) else json.dumps(risk)
                lines.append(f"- {line(text, 300)}")
    return [trim(v, 1500) for v in lines] or ["(nothing in its payload to show)"]


def body_of(item, brief=False):
    """The card's text. brief leaves out help text and option descriptions,
    for a card that doesn't fit a channel's limit whole."""
    payload = item.get("payload") or {}
    who = item.get("agent") or "An agent"
    if item["type"] == "approval":
        lines = [f"Approval · {who} asks: {APPROVAL_TYPES.get(item['kind'], item['kind'])}", ""]
        lines += approval_lines(item["kind"], payload)
        return "\n".join(lines)

    issue = item["issue"]["identifier"]
    lines = []
    kind = item["kind"]
    if kind == "ask_user_questions":
        lines.append(f"{issue} · {who} asks")
        title = item.get("title") or payload.get("title")
        questions = payload.get("questions") or []
        if title and (not questions or line(title, 999) != line(questions[0].get("prompt"), 999)):
            lines.append(trim(title, 300))
        several = len(questions) > 1
        shown = questions if supported(item) else questions[:3]
        for qi, question in enumerate(shown, 1):
            prompt = trim(question.get("prompt"), 300 if brief else 1000)
            lines += ["", f"{qi}) {prompt}" if several else prompt]
            if question.get("helpText") and not brief:
                lines.append(trim(question["helpText"], 500))
            if question.get("selectionMode") == "multi":
                lines.append("(Pick any.)")
            elif several:
                lines.append("(Pick one.)")
            for n, option in enumerate((question.get("options") or [])[:MAX_OPTIONS], 1):
                lines.append(f"{f'{qi}.{n}' if several else f'{n}.'} {line(option.get('label'), 300)}"
                             + (f": {line(option.get('description'), 400)}" if option.get("description") and not brief else ""))
            if question.get("allowOther") and several:
                lines.append(f"{qi}. Other: your own answer")
        if len(questions) > len(shown):
            lines.append(f"…and {len(questions) - len(shown)} more questions.")
        if several and supported(item):
            lines += ["", "Pick an answer for each, then Submit. Nothing is sent until then."]
    elif kind in ("request_confirmation", "request_checkbox_confirmation"):
        lines += [f"{issue} · {who} asks you to confirm", "", trim(payload.get("prompt"), 1000)]
        if kind == "request_checkbox_confirmation":
            for n, option in enumerate((payload.get("options") or [])[:MAX_OPTIONS], 1):
                lines.append(f"{n}. {line(option.get('label'), 300)}"
                             + (f": {line(option.get('description'), 400)}" if option.get("description") else ""))
        if payload.get("detailsMarkdown"):
            lines += ["", trim(payload["detailsMarkdown"], 300 if brief else 1500)]
    else:
        lines += [f"{issue} · {who} asks", "", line(item.get("title") or kind.replace("_", " "), 300)]
    if item.get("summary"):
        lines += ["", trim(item["summary"], 200 if brief else 600)]
    if not supported(item):
        lines += ["", "Answer this one in Paperclip."]
    return "\n".join(lines)


def buttons_of(item, selected, picks=None, texts=None):
    """Rows of (label, action). Actions: o<n> picks option n, t<n> toggles
    it, s submits the picks, ok accepts or approves, no rejects, and those
    starting with x ask for text first: xo<n> for a free-text option, xa
    for "Other", xno to reject with a reason. A form's are in form_question:
    q<i>o<n> marks a pick, xq<i>o<n> and xq<i> take text, and s sends them."""
    if not supported(item):
        return []
    payload = item["payload"]
    if item["type"] == "approval":
        return [[("Approve", "ok"), ("Reject", "no"), ("Reject with a note…", "xno")]]
    if form(item):
        picks, texts = picks or {}, texts or {}
        rows = []
        for qi, question in enumerate(questions_of(item)):
            picked = picks.get(question["id"]) or []
            several = question.get("selectionMode") == "multi"
            row = []
            for n, option in enumerate(question.get("options") or []):
                on = option.get("id") in picked
                mark = ("☑ " if on else "☐ ") if several else ("● " if on else "○ ")
                label = f"{mark}{qi + 1}.{n + 1} {line(option.get('label'), 50)}"
                row.append((label + ("…" if option.get("freeText") else ""),
                            f"xq{qi}o{n}" if option.get("freeText") else f"q{qi}o{n}"))
            if question.get("allowOther"):
                row.append((("✎ " if texts.get(question["id"]) else "") + f"{qi + 1}. Other…", f"xq{qi}"))
            rows.append(row)
        rows.append([(line(payload.get("submitLabel") or "Submit", 40), "s")])
        return rows

    rows = []
    options = options_of(item)
    for n, option in enumerate(options):
        label = f"{n + 1}. {line(option.get('label'), 60)}"
        if option.get("freeText"):
            rows.append((label + "…", f"xo{n}"))
        elif multi(item):
            rows.append((("☑ " if option.get("id") in selected else "☐ ") + label, f"t{n}"))
        else:
            rows.append((label, f"o{n}"))
    # One option a row while they fit, then up to five a row: Discord allows
    # five rows of five, and the controls take a row.
    per_row = 1 if len(rows) <= 4 else 5
    rows = [rows[i: i + per_row] for i in range(0, len(rows), per_row)]

    controls = []
    if item["kind"] == "ask_user_questions":
        question = payload["questions"][0]
        if multi(item):
            controls.append((line(payload.get("submitLabel") or "Submit", 40), "s"))
        if question.get("allowOther"):
            controls.append(("Other…", "xa"))
    else:
        controls.append((line(payload.get("acceptLabel") or "Accept", 40), "ok"))
        reject = line(payload.get("rejectLabel") or "Reject", 40)
        if payload.get("rejectRequiresReason"):
            controls.append((reject + "…", "xno"))
        else:
            controls.append((reject, "no"))
            if payload.get("allowDeclineReason", True):
                controls.append(("Reject with a reason…", "xno"))
    if controls:
        rows.append(controls)
    return rows


def link_of(item, link):
    if not link:
        return None
    if item["type"] == "approval":
        return f"{link}/approvals/{item['id']}"
    return f"{link}/issues/{item['issue']['identifier']}"


def answer_of(item, action, text, selected, picks=None, texts=None):
    """The call that answers item for a press, and what it says in a word.
    Raises ValueError with what to tell Justin when the press can't go."""
    payload = item["payload"]
    if form(item):
        if action != "s":
            raise ValueError("That button doesn't fit this question.")
        picks, texts = picks or {}, texts or {}
        answers = []
        for qi, question in enumerate(questions_of(item)):
            known = {o.get("id") for o in question.get("options") or []}
            ids = [i for i in (picks.get(question["id"]) or []) if i in known]
            other = (texts.get(question["id"]) or "").strip()
            if not ids and not other:
                if question.get("required", True):
                    raise ValueError(f"Answer question {qi + 1} first.")
                continue
            answers.append({"questionId": question["id"], "optionIds": ids, **({"otherText": other} if other else {})})
        return "POST", f"/api/issues/{item['issue']['id']}/interactions/{item['id']}/respond", {"answers": answers}, \
            picks_line(form_picks(item, picks, texts))
    if item["type"] == "approval":
        base = f"/api/approvals/{item['id']}"
        if action == "ok":
            return "POST", f"{base}/approve", {}, "Approved"
        if action == "no":
            return "POST", f"{base}/reject", {}, "Rejected"
        if action == "xno":
            return "POST", f"{base}/reject", {"decisionNote": text}, f"Rejected: {line(text, 200)}"
        raise ValueError("That button doesn't fit this approval.")

    base = f"/api/issues/{item['issue']['id']}/interactions/{item['id']}"
    options = options_of(item)
    labels = {option.get("id"): line(option.get("label"), 80) for option in options}

    def option(n):
        try:
            return options[int(n)]
        except (ValueError, IndexError):
            raise ValueError("That option isn't on this question any more.") from None

    if item["kind"] == "ask_user_questions":
        question = payload["questions"][0]
        picked = [i for i in selected if i in labels] if multi(item) else []
        if action.startswith("o"):
            chosen = option(action[1:])
            return "POST", f"{base}/respond", {"answers": [{"questionId": question["id"], "optionIds": [chosen["id"]]}]}, labels[chosen["id"]]
        if action.startswith("xo"):
            chosen = option(action[2:])
            ids = picked + [chosen["id"]] if chosen["id"] not in picked else picked
            what = ", ".join(labels[i] for i in ids) + f": {line(text, 200)}"
            return "POST", f"{base}/respond", {"answers": [{"questionId": question["id"], "optionIds": ids, "otherText": text}]}, what
        if action == "xa":
            what = ", ".join([labels[i] for i in picked] + [line(text, 200)])
            return "POST", f"{base}/respond", {"answers": [{"questionId": question["id"], "optionIds": picked, "otherText": text}]}, what
        if action == "s":
            if not picked and question.get("required", True):
                raise ValueError("Pick at least one first.")
            what = ", ".join(labels[i] for i in picked) or "nothing"
            return "POST", f"{base}/respond", {"answers": [{"questionId": question["id"], "optionIds": picked}]}, what
        raise ValueError("That button doesn't fit this question.")

    if action == "ok":
        if item["kind"] == "request_checkbox_confirmation":
            picked = [i for i in selected if i in labels]
            least, most = payload.get("minSelected") or 0, payload.get("maxSelected")
            if len(picked) < least:
                raise ValueError(f"Pick at least {least} first.")
            if most is not None and len(picked) > most:
                raise ValueError(f"Pick at most {most}.")
            what = "Accepted" + (": " + ", ".join(labels[i] for i in picked) if picked else "")
            return "POST", f"{base}/accept", {"selectedOptionIds": picked}, what
        return "POST", f"{base}/accept", {}, "Accepted"
    if action == "no":
        if payload.get("rejectRequiresReason"):
            raise ValueError("This one needs a reason.")
        return "POST", f"{base}/reject", {}, "Rejected"
    if action == "xno":
        return "POST", f"{base}/reject", {"reason": text}, f"Rejected: {line(text, 200)}"
    raise ValueError("That button doesn't fit this confirmation.")


def text_prompt(item, action):
    """(title, label) for asking Justin to type: a Discord form's title and
    field, or a Telegram reply prompt."""
    where = item["issue"]["identifier"] if item["type"] == "interaction" else "Approval"
    if action == "xno":
        label = (item["payload"].get("rejectReasonLabel") if item["type"] == "interaction" else None) or "Why you're rejecting it"
        return f"{where}: reject", label
    if action.startswith("xq"):
        try:
            qi, question, _, option = form_question(item, action)
        except ValueError:
            return f"{where}: your answer", "Other"
        return f"{where}: question {qi + 1}", line(option.get("label") if option else question.get("prompt"), 80)
    if action.startswith("xo"):
        options = options_of(item)
        try:
            return f"{where}: your answer", line(options[int(action[2:])].get("label"), 80)
        except (ValueError, IndexError):
            pass
    return f"{where}: your answer", "Other"


def outcome_of(item, current):
    """{"via": "Paperclip" or None, "what": ...} for an item that's no
    longer pending, from what Paperclip says of it now (None if it's gone)."""
    if current is None:
        return {"via": None, "what": "it's gone from Paperclip"}
    status = current.get("status") or "?"
    if item["type"] == "approval":
        note = current.get("decisionNote")
        what = status.replace("_", " ").capitalize() + (f": {line(note, 200)}" if note else "")
        return {"via": "Paperclip" if status in ANSWERED else None, "what": what}
    result = current.get("result") or {}
    if status == "pending":
        return {"via": None, "what": "its issue was closed"}
    if status == "answered":
        # Option ids are only unique within a question.
        questions = (current.get("payload") or item["payload"]).get("questions") or []
        by_id = {q.get("id"): (n, q) for n, q in enumerate(questions, 1)}
        parts = []
        for answer in result.get("answers") or []:
            n, question = by_id.get(answer.get("questionId"), (None, {}))
            labels = {o.get("id"): line(o.get("label"), 80) for o in question.get("options") or []}
            said = [labels.get(i, i) for i in answer.get("optionIds") or []]
            if answer.get("otherText"):
                said.append(line(answer["otherText"], 200 if len(questions) < 2 else 100))
            if said:
                parts.append((f"{n}. " if len(questions) > 1 and n else "") + ", ".join(said))
        return {"via": "Paperclip", "what": ("; " if len(questions) > 1 else ", ").join(parts) or "answered"}
    if status in ("accepted", "rejected"):
        labels = {o.get("id"): line(o.get("label"), 80) for o in options_of(item)}
        picked = [labels.get(i, i) for i in result.get("selectedOptionIds") or []]
        reason = result.get("reason")
        what = status.capitalize() + (": " + ", ".join(picked) if picked else "") + (f": {line(reason, 200)}" if reason else "")
        return {"via": "Paperclip", "what": what}
    return {"via": None, "what": status.replace("_", " ")}


def render(entry, link):
    """The card for an entry: its text, its rows of (label, action), its
    link, and the token its buttons carry."""
    item, done = entry["item"], entry.get("done")
    picks, texts = entry.get("picks") or {}, entry.get("texts") or {}
    if done:
        status = f"✓ Answered in {done['via']}: {done['what']}" if done.get("via") else f"No longer waiting: {done['what']}."
        rows = []
    else:
        rows = buttons_of(item, entry.get("selected") or [], picks, texts)
        picked = form_picks(item, picks, texts) if form(item) else []
        status = f"So far: {picks_line(picked)}" if picked else None
    return {"token": entry["token"], "text": body_of(item), "brief": body_of(item, brief=True),
            "status": status, "rows": rows, "url": link_of(item, link)}


def card_text(card, limit):
    """The card's text within limit: whole if it fits, else without the
    descriptions, trimmed if even that doesn't."""
    status = card.get("status")
    room = limit - (len(status) + 2 if status else 0)
    text = card["text"]
    if len(text) > room and card.get("brief"):
        text = card["brief"]
    return trim(text, room) + (f"\n\n{status}" if status else "")


def needs_text(action):
    return action.startswith("x")


def token_of(key):
    return hashlib.sha256(key.encode()).hexdigest()[:8]


class Bridge:
    def __init__(self, paperclip, state_dir, link=None, prefix="LAB", poll=20, retry=20):
        self.paperclip = paperclip
        self.dir = pathlib.Path(state_dir)
        self.link = link
        self.prefix = prefix
        self.poll = poll
        self.retry = retry
        self.channels = []
        self.lock = asyncio.Lock()
        # Set by a nudge; a nudge during a pass makes one more pass.
        self.wake = asyncio.Event()
        self.company = None
        try:
            self.state = json.loads((self.dir / "state.json").read_text())
        except FileNotFoundError:
            self.state = {}
        except ValueError:
            log.warning("state.json can't be read, so what's waiting will be sent again")
            self.state = {}
        self.state.setdefault("items", {})
        try:
            self.status = json.loads((self.dir / "status.json").read_text())
        except (FileNotFoundError, ValueError):
            self.status = {}
        self.status["started"] = iso(now())
        self.status.setdefault("answered", {})
        self.status.setdefault("recent", [])
        self.errors = []

    # State and status.

    def save(self):
        write_json(self.dir / "state.json", self.state)

    def save_status(self):
        self.status["channels"] = [c.name for c in self.channels]
        self.status["waiting"] = [
            {"key": key, "issue": (e["item"].get("issue") or {}).get("identifier"), "kind": e["item"]["kind"],
             "sent": sorted(e.get("sent") or {}), "created": e["item"].get("created"),
             "sent_at": e.get("sent_at") or {}, "answered": e.get("done")}
            for key, e in sorted(self.state["items"].items())]
        # agent-watch reads it as another user.
        write_json(self.dir / "status.json", self.status, 0o644)

    def problem(self, text):
        log.warning("%s", text)
        self.errors.append(text)

    def entry(self, token):
        return next(((k, e) for k, e in self.state["items"].items() if e["token"] == token), (None, None))

    def card(self, entry):
        return render(entry, self.link)

    # Reading Paperclip.

    def read(self):
        """Every pending item, by key."""
        call = self.paperclip.call
        if self.company is None:
            company = next((c for c in call("GET", "/api/companies") or [] if c.get("issuePrefix") == self.prefix), None)
            if company is None:
                raise Failure(f"the board key sees no company with the prefix {self.prefix}")
            self.company = company["id"]
        base = f"/api/companies/{self.company}"
        agents = {a["id"]: a.get("name") for a in call("GET", f"{base}/agents") or []}
        items = {}
        for issue in call("GET", f"{base}/issues?status={OPEN_ISSUE}&limit=1000") or []:
            for i in call("GET", f"/api/issues/{issue['id']}/interactions") or []:
                if i.get("status") != "pending" or i.get("addresseeAgentId"):
                    continue
                items[f"i:{i['id']}"] = {
                    "type": "interaction", "kind": i.get("kind"), "id": i["id"], "created": i.get("createdAt") or "",
                    "issue": {"id": issue["id"], "identifier": issue.get("identifier"), "title": issue.get("title")},
                    "agent": agents.get(i.get("createdByAgentId")) or agents.get(issue.get("assigneeAgentId")),
                    "title": i.get("title"), "summary": i.get("summary"), "payload": i.get("payload") or {}}
        for a in call("GET", f"{base}/approvals?status=pending") or []:
            items[f"a:{a['id']}"] = {
                "type": "approval", "kind": a.get("type"), "id": a["id"], "created": a.get("createdAt") or "",
                "agent": agents.get(a.get("requestedByAgentId")), "payload": a.get("payload") or {}}
        return items

    def current(self, item):
        """What Paperclip says of an item now, or None if it's gone."""
        if item["type"] == "approval":
            try:
                return self.paperclip.call("GET", f"/api/approvals/{item['id']}")
            except Failure as err:
                if "HTTP 404" in str(err):
                    return None
                raise
        try:
            listed = self.paperclip.call("GET", f"/api/issues/{item['issue']['id']}/interactions") or []
        except Failure as err:
            if "HTTP 404" in str(err):
                return None
            raise
        return next((i for i in listed if i.get("id") == item["id"]), None)

    # A pass.

    async def edit_copies(self, entry):
        card = self.card(entry)
        for channel in self.channels:
            refs = (entry.get("sent") or {}).get(channel.name, [])
            if refs and channel.trouble():
                self.problem(f"{channel.name}: couldn't update a message: {channel.trouble()}")
                continue
            for ref in refs:
                try:
                    await channel.edit(ref, card)
                except Exception as err:  # noqa: BLE001 - a channel's trouble shouldn't stop the others
                    self.problem(f"{channel.name}: couldn't update a message: {line(err, 200)}")

    def finish(self, key, entry):
        done = entry.get("done") or {}
        self.status["recent"] = ([{"key": key, "issue": (entry["item"].get("issue") or {}).get("identifier"),
                                   "kind": entry["item"]["kind"], "sent": sorted(entry.get("sent") or {}),
                                   "created": entry["item"].get("created"), "sent_at": entry.get("sent_at") or {},
                                   "via": done.get("via"), "what": done.get("what"), "at": iso(now())}]
                                 + self.status["recent"])[:20]
        del self.state["items"][key]

    async def pass_once(self):
        self.errors = []
        try:
            live = await asyncio.to_thread(self.read)
        except Failure as err:
            self.problem(f"Paperclip: {err}")
            live = None
        async with self.lock:
            if live is not None:
                for key, item in sorted(live.items(), key=lambda kv: kv[1]["created"]):
                    entry = self.state["items"].get(key)
                    if entry is None:
                        entry = self.state["items"][key] = {"token": token_of(key), "item": item, "sent": {},
                                                            "selected": default_selection(item)}
                    if entry.get("done"):
                        continue
                    if entry["item"] != item:
                        entry["item"] = item
                        await self.edit_copies(entry)
                    for channel in self.channels:
                        # A channel that's down is said once below, not per item.
                        if channel.name in entry["sent"] or channel.trouble():
                            continue
                        try:
                            ref = await channel.send(self.card(entry))
                        except Exception as err:  # noqa: BLE001
                            self.problem(f"{channel.name}: couldn't send {key}: {line(err, 200)}")
                            continue
                        entry["sent"][channel.name] = [ref]
                        # When it reached each channel, against when it was asked.
                        entry.setdefault("sent_at", {})[channel.name] = iso(now())
                        log.info("sent %s (%s) to %s", (item.get("issue") or {}).get("identifier") or "an approval",
                                 item["kind"], channel.name)
                        self.save()
                for key in [k for k in self.state["items"] if k not in live]:
                    entry = self.state["items"][key]
                    if not entry.get("done"):
                        try:
                            current = await asyncio.to_thread(self.current, entry["item"])
                        except Failure as err:
                            self.problem(f"Paperclip: {err}")
                            continue
                        if current is not None and current.get("status") == "pending" and entry["item"]["type"] == "approval":
                            continue
                        entry["done"] = outcome_of(entry["item"], current)
                        if entry["done"]["via"]:
                            self.count(entry["done"]["via"])
                        await self.edit_copies(entry)
                    self.finish(key, entry)
                self.save()
            for channel in self.channels:
                trouble = channel.trouble()
                if trouble:
                    self.problem(f"{channel.name}: {trouble}")
            if self.errors:
                self.status["last_error"] = "; ".join(dict.fromkeys(self.errors))
                self.status["last_error_at"] = iso(now())
            else:
                self.status["last_ok"] = iso(now())
            self.save_status()

    def count(self, via):
        self.status["answered"][via] = self.status["answered"].get(via, 0) + 1

    def nudge(self):
        """Something changed in Paperclip: read it now, not at the next
        poll. paperclip-events sends SIGHUP for this."""
        self.wake.set()

    async def run(self):
        while True:
            self.wake.clear()
            try:
                await self.pass_once()
                ok = not self.errors
            except Exception:  # noqa: BLE001 - log it and try again soon
                log.exception("pass failed")
                ok = False
            # A pass that went wrong tries again after `retry` seconds, since
            # no event may come to say a channel or Paperclip is back.
            try:
                await asyncio.wait_for(self.wake.wait(), self.poll if ok else min(self.poll, self.retry))
            except asyncio.TimeoutError:
                pass

    # Presses.

    def prompt_for(self, token, action):
        _, entry = self.entry(token)
        if entry is None:
            return "Answer", "Your answer"
        return text_prompt(entry["item"], action)

    async def press(self, via, token, action, text=None):
        """Answer for a press in via (Telegram or Discord), whose adapter has
        already checked who pressed. Returns (ok, what to tell Justin)."""
        async with self.lock:
            key, entry = self.entry(token)
            if entry is None:
                return False, "That's no longer waiting in Paperclip."
            if entry.get("done"):
                return False, "Already answered."
            item = entry["item"]
            if not supported(item):
                return False, "Answer this one in Paperclip."
            if needs_text(action) and not (text or "").strip():
                return False, "That needs some text."
            if form(item) and action != "s":
                # A form only marks picks; Submit sends them all.
                try:
                    _, question, _, option = form_question(item, action)
                except ValueError as err:
                    return False, str(err)
                qid = question["id"]
                texts = entry.setdefault("texts", {})
                picked = entry.setdefault("picks", {}).setdefault(qid, [])
                if needs_text(action):
                    texts[qid] = trim(text, 4000)
                if option is not None:
                    if option["id"] in picked and not needs_text(action):
                        picked.remove(option["id"])  # a second press clears it
                    elif question.get("selectionMode") != "multi":
                        picked[:] = [option["id"]]
                    elif option["id"] not in picked:
                        picked.append(option["id"])
                # A free-text option's text goes when that option does.
                free = {o.get("id") for o in question.get("options") or [] if o.get("freeText")}
                if free and not free & set(picked) and not question.get("allowOther"):
                    texts.pop(qid, None)
                self.save()
                await self.edit_copies(entry)
                return True, "Kept. Submit sends every answer." if needs_text(action) else ""
            if action.startswith("t"):
                options = options_of(item)
                try:
                    option_id = options[int(action[1:])]["id"]
                except (ValueError, IndexError):
                    return False, "That option isn't on this question any more."
                selected = entry.setdefault("selected", [])
                if option_id in selected:
                    selected.remove(option_id)
                else:
                    selected.append(option_id)
                self.save()
                await self.edit_copies(entry)
                return True, ""
            try:
                method, path, body, what = answer_of(item, action, (text or "").strip(), entry.get("selected") or [],
                                                     entry.get("picks") or {}, entry.get("texts") or {})
            except ValueError as err:
                return False, str(err)
            try:
                await asyncio.to_thread(self.paperclip.call, method, path, body)
            except Failure as err:
                return False, f"Paperclip didn't take it: {line(err, 160)}"
            entry["done"] = {"via": via, "what": what}
            self.count(via)
            log.info("%s answered from %s", (item.get("issue") or {}).get("identifier") or "an approval", via)
            self.save()
            await self.edit_copies(entry)
            self.save_status()
            return True, f"Sent: {line(what, 150)}"


# Telegram, over the Bot API with long polling: nothing reaches us inbound.

class TelegramApi:
    def __init__(self, token, base="https://api.telegram.org"):
        self.token = token
        self.base = base

    def __call__(self, method, params, timeout=30):
        req = urllib.request.Request(f"{self.base}/bot{self.token}/{method}", data=json.dumps(params).encode(),
                                     method="POST", headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                answer = json.loads(resp.read())
        except urllib.error.HTTPError as err:
            try:
                answer = json.loads(err.read(2000))
            except ValueError:
                answer = {"description": f"HTTP {err.code}"}
        except (urllib.error.URLError, OSError, ValueError) as err:
            raise Failure(f"{method}: can't reach Telegram: {line(getattr(err, 'reason', err), 120)}".replace(self.token, "<token>")) from None
        if not answer.get("ok"):
            raise Failure(f"{method}: {line(answer.get('description') or 'failed', 200)}".replace(self.token, "<token>"))
        return answer.get("result")


class Telegram:
    name = "Telegram"
    # Telegram's limit is 4096 UTF-16 units; emoji count twice.
    LIMIT = 4000

    def __init__(self, api, user, bridge):
        self.api = api
        self.user = int(user)
        self.bridge = bridge
        self.last_poll = None
        self.error = None
        bridge.state.setdefault("telegram", {}).setdefault("prompts", {})

    async def call(self, method, params, timeout=30):
        return await asyncio.to_thread(self.api, method, params, timeout)

    def markup(self, card):
        rows = [[{"text": label, "callback_data": f"{card['token']}:{action}"} for label, action in row] for row in card["rows"]]
        if card["url"]:
            rows.append([{"text": "Open in Paperclip", "url": card["url"]}])
        return {"inline_keyboard": rows}

    async def send(self, card):
        message = await self.call("sendMessage", {
            "chat_id": self.user, "text": card_text(card, self.LIMIT), "reply_markup": self.markup(card),
            "link_preview_options": {"is_disabled": True}})
        return [message["chat"]["id"], message["message_id"]]

    async def edit(self, ref, card):
        try:
            await self.call("editMessageText", {
                "chat_id": ref[0], "message_id": ref[1], "text": card_text(card, self.LIMIT),
                "reply_markup": self.markup(card), "link_preview_options": {"is_disabled": True}})
        except Failure as err:
            if "message is not modified" not in str(err):
                raise

    def trouble(self):
        if self.error:
            return self.error
        if self.last_poll is not None and (now() - self.last_poll).total_seconds() > 120:
            return "no answer from Telegram for 2 minutes"
        return None

    async def say(self, text, reply_to=None, force_reply=False):
        params = {"chat_id": self.user, "text": trim(text, self.LIMIT)}
        if reply_to:
            params["reply_parameters"] = {"message_id": reply_to, "allow_sending_without_reply": True}
        if force_reply:
            params["reply_markup"] = {"force_reply": True}
        return await self.call("sendMessage", params)

    async def handle(self, update):
        prompts = self.bridge.state["telegram"]["prompts"]
        query = update.get("callback_query")
        if query:
            sender = (query.get("from") or {}).get("id")
            chat = ((query.get("message") or {}).get("chat") or {})
            if sender != self.user or chat.get("type") != "private":
                log.warning("ignored a Telegram press from user %s in a %s chat", sender, chat.get("type"))
                return
            token, _, action = (query.get("data") or "").partition(":")
            if needs_text(action):
                title, label = self.bridge.prompt_for(token, action)
                sent = await self.say(f"{title}. {label}: reply to this message with it.", force_reply=True)
                prompts[str(sent["message_id"])] = [token, action]
                # Prompts never answered are dropped, oldest first.
                for old in sorted(prompts, key=int)[:-50]:
                    del prompts[old]
                self.bridge.save()
                await self.call("answerCallbackQuery", {"callback_query_id": query["id"], "text": "Reply with your text"})
                return
            _, notice = await self.bridge.press(self.name, token, action)
            await self.call("answerCallbackQuery", {"callback_query_id": query["id"], "text": trim(notice, 200)})
            return

        message = update.get("message")
        if not message:
            return
        sender = (message.get("from") or {}).get("id")
        chat = message.get("chat") or {}
        if sender != self.user or chat.get("type") != "private":
            log.warning("ignored a Telegram message from user %s in a %s chat", sender, chat.get("type"))
            return
        replied = str((message.get("reply_to_message") or {}).get("message_id"))
        if replied in prompts:
            token, action = prompts.pop(replied)
            self.bridge.save()
            _, notice = await self.bridge.press(self.name, token, action, message.get("text") or "")
            await self.say(notice, reply_to=message.get("message_id"))
            return
        await self.say("I only pass on Paperclip's questions. Answer with the buttons, or reply to my prompt for text.",
                       reply_to=message.get("message_id"))

    async def run(self):
        state = self.bridge.state["telegram"]
        backoff = 5
        while True:
            try:
                updates = await self.call("getUpdates", {
                    "offset": state.get("offset", 0), "timeout": 25,
                    "allowed_updates": ["message", "callback_query"]}, timeout=40)
            except Failure as err:
                self.error = str(err)
                log.warning("Telegram: %s", err)
                await asyncio.sleep(backoff)
                backoff = min(backoff * 2, 120)
                continue
            backoff = 5
            self.last_poll, self.error = now(), None
            for update in updates or []:
                state["offset"] = update["update_id"] + 1
                try:
                    await self.handle(update)
                except Exception:  # noqa: BLE001 - one bad update shouldn't stop the rest
                    log.exception("Telegram update %s", update.get("update_id"))
                self.bridge.save()


# Discord, over its gateway through discord.py. Buttons are DynamicItems,
# so a press works after a restart; text comes in a form.

def discord_channel(token, user, bridge):
    import discord

    channel = None

    class Press(discord.ui.DynamicItem[discord.ui.Button], template=r"bb:(?P<token>[0-9a-f]{8}):(?P<action>[a-z0-9]{1,6})"):
        def __init__(self, token, action, label="·", style=discord.ButtonStyle.secondary, row=None):
            super().__init__(discord.ui.Button(label=label, style=style, custom_id=f"bb:{token}:{action}"), row=row)
            self.token, self.action = token, action

        @classmethod
        async def from_custom_id(cls, interaction, item, match, /):
            return cls(match["token"], match["action"], label=item.label or "·")

        async def callback(self, interaction):
            await channel.pressed(interaction, self.token, self.action)

    class Reason(discord.ui.Modal):
        def __init__(self, title, label, token, action):
            super().__init__(title=trim(title, 45), timeout=900)
            self.field = discord.ui.TextInput(label=trim(label, 45), style=discord.TextStyle.paragraph, max_length=4000)
            self.add_item(self.field)
            self.token, self.action = token, action

        async def on_submit(self, interaction):
            await interaction.response.defer()
            ok, notice = await bridge.press(Discord.name, self.token, self.action, self.field.value)
            if not ok:
                await interaction.followup.send(notice)

    class Client(discord.Client):
        async def setup_hook(self):
            self.add_dynamic_items(Press)

        # What waited for Discord, as at a restart, goes out once it's connected.
        async def on_ready(self):
            bridge.nudge()

    class Discord:
        name = "Discord"
        LIMIT = 1900

        def __init__(self):
            self.user = int(user)
            self.client = Client(intents=discord.Intents.none())

        def style(self, action):
            if action == "ok":
                return discord.ButtonStyle.success
            if action in ("no", "xno"):
                return discord.ButtonStyle.danger
            return discord.ButtonStyle.primary if action[:1] in ("o", "t") or action.startswith("xo") else discord.ButtonStyle.secondary

        def view(self, card):
            view = discord.ui.View(timeout=None)
            for r, row in enumerate(card["rows"][:5]):
                for label, action in row[:5]:
                    view.add_item(Press(card["token"], action, label=trim(label, 80), style=self.style(action), row=r))
            if card["url"]:
                rows = card["rows"][:5]
                row = len(rows) if len(rows) < 5 else 4
                view.add_item(discord.ui.Button(label="Open in Paperclip", url=card["url"], row=row))
            return view

        async def ready(self):
            await asyncio.wait_for(self.client.wait_until_ready(), 15)

        async def send(self, card):
            await self.ready()
            person = self.client.get_user(self.user) or await self.client.fetch_user(self.user)
            dm = person.dm_channel or await person.create_dm()
            message = await dm.send(card_text(card, self.LIMIT), view=self.view(card))
            return [dm.id, message.id]

        async def edit(self, ref, card):
            await self.ready()
            dm = self.client.get_partial_messageable(ref[0], type=discord.ChannelType.private)
            await dm.get_partial_message(ref[1]).edit(content=card_text(card, self.LIMIT), view=self.view(card))

        def trouble(self):
            if self.client.is_closed() or not self.client.is_ready():
                return "not connected to Discord"
            return None

        async def pressed(self, interaction, token, action):
            if interaction.user.id != self.user or interaction.guild_id is not None:
                log.warning("ignored a Discord press from user %s in %s", interaction.user.id,
                            "a server" if interaction.guild_id is not None else "a DM")
                return
            if needs_text(action):
                title, label = bridge.prompt_for(token, action)
                await interaction.response.send_modal(Reason(title, label, token, action))
                return
            await interaction.response.defer()
            ok, notice = await bridge.press(self.name, token, action)
            if not ok:
                await interaction.followup.send(notice)

        async def run(self):
            await self.client.start(token)

    channel = Discord()
    return channel


def credential(name):
    return (pathlib.Path(os.environ["CREDENTIALS_DIRECTORY"]) / name).read_text().strip()


async def main():
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    bridge = Bridge(Paperclip(os.environ.get("PAPERCLIP_URL", "http://127.0.0.1:3100"), credential("paperclip-key")),
                    os.environ["STATE_DIR"], os.environ.get("PAPERCLIP_LINK", "").rstrip("/") or None,
                    os.environ.get("COMPANY_PREFIX", "LAB"), int(os.environ.get("POLL_SECONDS", "20")))
    asyncio.get_running_loop().add_signal_handler(signal.SIGHUP, bridge.nudge)
    if os.environ.get("TELEGRAM_USER"):
        bridge.channels.append(Telegram(TelegramApi(credential("telegram-token")), os.environ["TELEGRAM_USER"], bridge))
    if os.environ.get("DISCORD_USER"):
        bridge.channels.append(discord_channel(credential("discord-token"), os.environ["DISCORD_USER"], bridge))
    if not bridge.channels:
        sys.exit("no channel is on: set TELEGRAM_USER or DISCORD_USER")
    log.info("bridging to %s", ", ".join(c.name for c in bridge.channels))
    await asyncio.gather(bridge.run(), *(c.run() for c in bridge.channels))


if __name__ == "__main__":
    asyncio.run(main())
