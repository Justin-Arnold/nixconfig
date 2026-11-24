#!/usr/bin/env python3
"""notes: the vault service on the agents host.

Justin's second brain is one Obsidian vault on Obsidian Sync. notes-sync
(Obsidian's headless client) keeps this host's copy at VAULT, and this
service owns that copy for the Hermes agents. They reach it only through
their notes MCP server (modules/roles/hermes-agents/notes-mcp), which sends
one JSON request per connection to this service's Unix socket.

Who's calling comes from the kernel (SO_PEERCRED): the socket hands over the
caller's uid, and NOTES_AGENTS maps the agents' uids to their names. Any
other uid is refused, and the agents hold no credential for any of this.

The vault is also a git repository, kept only on this host (Obsidian skips
dot-folders, so .git never syncs). Every change an agent makes is one
commit under its name; every change that arrives through Sync, from Justin's
devices, is committed as "Obsidian Sync" before an agent's request runs and
every WATCH_SECONDS. That history is what note_history reads, what an undo
restores from, and what notes-scan.py checks for secrets.

What it refuses:
- paths outside the vault, through a symlink, in a dot-folder, or not
  ending in .md, and a new path that differs from an existing one only in
  case (Justin's Macs would treat them as one);
- text an agent adds that looks like a secret or private data (the Jev
  server's patterns, loaded from NOTES_PATTERNS, plus the ones below). Reads
  show such text as a redaction marker, and a write that carries the marker
  back is refused, so a rewrite can't destroy what was hidden;
- a rewrite of a note that changed since the agent read it;
- more than WRITES_PER_HOUR writes an hour per agent, and notes over
  MAX_NOTE_BYTES.

Every file is written to a dot-named temporary file and renamed into place,
so Sync never uploads half a note.

Environment: VAULT, STATE_DIR (status.json), NOTES_AGENTS (uid=name,...),
NOTES_PATTERNS (the Jev server), WATCH_SECONDS (10), WRITES_PER_HOUR (120),
MAX_NOTE_BYTES (262144), and NOTES_LISTEN, a socket path to bind, only when
systemd doesn't pass a socket (LISTEN_FDS).
"""
import collections
import datetime
import difflib
import importlib.util
import json
import os
import pathlib
import posixpath
import re
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unicodedata
import urllib.parse

VAULT = pathlib.Path(os.environ.get("VAULT", "/var/lib/notes/vault"))
STATE_DIR = pathlib.Path(os.environ.get("STATE_DIR", "/var/lib/notes"))
WATCH_SECONDS = float(os.environ.get("WATCH_SECONDS", "10"))
WRITES_PER_HOUR = int(os.environ.get("WRITES_PER_HOUR", "120"))
MAX_NOTE_BYTES = int(os.environ.get("MAX_NOTE_BYTES", "262144"))

MAX_REQUEST = 1_100_000
MAX_INSERT = 65_536
MAX_MESSAGE = 200
MAX_PATH_BYTES = 512
MAX_PART_BYTES = 200
MAX_READ_BYTES = 8_000_000
MAX_INDEX_BYTES = 1_000_000
MAX_LINK_UPDATES = 200
DEADLINE = 50

SYNC_AUTHOR = ("Obsidian Sync", "sync@notes.invalid")
COMMITTER = ("notes service", "notes@agents.invalid")
MARKER = "⟦redacted"
BAD_CHARS = set('*"<>:|?#^[]\\')


class Refused(Exception):
    """A request this service won't carry out, with the reason the agent sees."""


# Secrets and private data ------------------------------------------------

def _load_patterns():
    path = os.environ.get("NOTES_PATTERNS")
    if not path:
        return []
    spec = importlib.util.spec_from_file_location("jev_server", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    # The generic "password: value" rule is replaced by GENERIC below, which
    # lets placeholders through.
    return [(rx, kind, re.sub(r"[^a-z0-9]+", "-", kind.lower().removeprefix("a ").removeprefix("an ")).strip("-"))
            for rx, kind in module.SECRET_PATTERNS if "credential" not in kind]


EXTRA_PATTERNS = [
    (re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"), "a JSON web token", "jwt"),
    (re.compile(r"\b\d{8,10}:AA[A-Za-z0-9_-]{33}\b"), "a Telegram bot token", "telegram-token"),
    (re.compile(r"\b[MN][A-Za-z\d]{23,25}\.[\w-]{6}\.[\w-]{27,38}\b"), "a Discord bot token", "discord-token"),
    (re.compile(r"\bdp\.(?:st|pt|sa|ct|scim|audit)\.[A-Za-z0-9_.-]{20,}"), "a Doppler token", "doppler-token"),
    (re.compile(r"\btskey-[A-Za-z0-9-]{20,}"), "a Tailscale key", "tailscale-key"),
    (re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b"), "a Google API key", "google-key"),
    (re.compile(r"\b[rs]k_live_[0-9A-Za-z]{20,}"), "a Stripe key", "stripe-key"),
    (re.compile(r"\bhf_[A-Za-z0-9]{30,}"), "a Hugging Face token", "huggingface-token"),
    (re.compile(r"\bnpm_[A-Za-z0-9]{36}\b"), "an npm token", "npm-token"),
    (re.compile(r"PVEAPIToken=\S+"), "a Proxmox API token", "proxmox-token"),
    (re.compile(r"\b(?!000|666|9\d\d)\d{3}-(?!00)\d{2}-(?!0000)\d{4}\b"), "a social security number", "ssn"),
]
GENERIC = re.compile(r"(?i)\b(?:password|passwd|passphrase|secret|token|api[_-]?key)\s*[:=]\s*(\S{8,})")
# A value that only says where a secret is, or stands in for one.
PLACEHOLDER = re.compile(r"""[`'"]?(?:<[^>]*>|\$\{[^}]*\}|\.{3,}|\*{3,}|[a-z0-9][a-z0-9._-]*(?:/[a-z0-9._-]+)+)[`'"]?[.,;:)]*""")
CARD = re.compile(r"(?<![\d-])(?:\d[ -]?){12,18}\d(?![\d-])")
IBAN = re.compile(r"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]){11,30}\b")
PRIVATE_KINDS = {"ssn", "card", "iban"}
PATTERNS = _load_patterns() + EXTRA_PATTERNS


def _luhn(digits):
    total = 0
    for i, d in enumerate(reversed(digits)):
        n = int(d)
        if i % 2:
            n = n * 2 - 9 if n > 4 else n * 2
        total += n
    return total % 10 == 0


def _card(digits):
    if not 13 <= len(digits) <= 19 or not _luhn(digits):
        return False
    two, four = int(digits[:2]), int(digits[:4])
    return (digits[0] == "4" or 51 <= two <= 55 or 2221 <= four <= 2720 or two in (34, 37, 65)
            or four == 6011 or 644 <= int(digits[:3]) <= 649)


def _iban(value):
    s = value.replace(" ", "")
    if not 15 <= len(s) <= 34:
        return False
    moved = s[4:] + s[:4]
    try:
        return int("".join(str(int(c, 36)) for c in moved)) % 97 == 1
    except ValueError:
        return False


def secret_hits(text):
    """(start, end, description, slug) for everything in text that looks like a secret or private data."""
    hits = []
    for rx, kind, slug in PATTERNS:
        hits += [(m.start(), m.end(), kind, slug) for m in rx.finditer(text)]
    for m in GENERIC.finditer(text):
        if not PLACEHOLDER.fullmatch(m.group(1)):
            hits.append((m.start(1), m.end(1), "something that looks like a credential", "credential"))
    for m in CARD.finditer(text):
        if _card(re.sub(r"\D", "", m.group())):
            hits.append((m.start(), m.end(), "a card number", "card"))
    for m in IBAN.finditer(text):
        if _iban(m.group()):
            hits.append((m.start(), m.end(), "a bank account number (IBAN)", "iban"))
    return sorted(hits)


def refuse_secrets(text, where):
    hits = secret_hits(text)
    if hits:
        raise Refused(f"{where} looks like it holds {hits[0][2]}, which never goes in the vault; write where it "
                      "lives instead (its SOPS secret's name, or \"in 1Password\")")
    if MARKER in text:
        raise Refused(f"{where} has a redaction marker in it: leave the redacted part of the note as it is, and "
                      "change the rest with replace_in_note")


def redact(text):
    """text with every secret-shaped part replaced by a marker, and whether anything was."""
    out, last = [], 0
    for start, end, kind, _ in secret_hits(text):
        if start < last:
            continue
        out += [text[last:start], f"{MARKER}: {kind}⟧"]
        last = end
    out.append(text[last:])
    return "".join(out), last > 0


# Git ----------------------------------------------------------------------

GIT_OPTS = ["-c", "core.hooksPath=/dev/null", "-c", "core.symlinks=false", "-c", "core.fsmonitor=false",
            "-c", "commit.gpgsign=false", "-c", "core.quotepath=off", "-c", "core.autocrlf=false",
            "-c", "protocol.allow=never", "-c", "safe.directory=*"]


def git(*args, check=True, env=None, raw=False):
    full_env = {"PATH": os.environ.get("PATH", ""), "HOME": str(STATE_DIR), "LC_ALL": "C.UTF-8",
                "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0",
                "GIT_OPTIONAL_LOCKS": "0"}
    full_env.update(env or {})
    proc = subprocess.run(["git", *GIT_OPTS, "-C", str(VAULT), *args], capture_output=True, env=full_env,
                          timeout=DEADLINE)
    if check and proc.returncode != 0:
        raise RuntimeError(f"git {args[0]} failed: {proc.stderr.decode(errors='replace').strip()[:300]}")
    return proc if raw else proc.stdout.decode("utf-8", "replace")


def init_repo():
    VAULT.mkdir(parents=True, exist_ok=True)
    if not (VAULT / ".git").is_dir():
        git("init", "-q", "-b", "main")
    # Dot-files are Obsidian's config, its trash and this service's
    # temporary files; Sync skips them too.
    (VAULT / ".git" / "info").mkdir(exist_ok=True)
    (VAULT / ".git" / "info" / "exclude").write_text(".*\n")


def has_head():
    return git("rev-parse", "-q", "--verify", "HEAD", check=False, raw=True).returncode == 0


def commit(paths, author, message, trailers=""):
    """Commits the given paths (and only them) under author; the new commit's id, or None if nothing changed."""
    git("add", "-A", "--", *paths)
    if git("diff", "--cached", "--quiet", check=False, raw=True).returncode == 0:
        return None
    env = {"GIT_AUTHOR_NAME": author[0], "GIT_AUTHOR_EMAIL": author[1],
           "GIT_COMMITTER_NAME": COMMITTER[0], "GIT_COMMITTER_EMAIL": COMMITTER[1]}
    args = ["commit", "-q", "--no-verify", "-m", message] + (["-m", trailers] if trailers else [])
    git(*args, env=env)
    return git("rev-parse", "HEAD").strip()


def settle():
    """Commits whatever changed outside this service (that is, through Sync) as Obsidian Sync."""
    status = git("status", "--porcelain", "-z", "--untracked-files=all")
    if not status:
        return None
    changed = sorted({entry[3:] for entry in status.split("\0") if len(entry) > 3})
    listed = ", ".join(changed[:10]) + (f" and {len(changed) - 10} more" if len(changed) > 10 else "")
    return commit(["."], SYNC_AUTHOR, f"Obsidian Sync: {len(changed)} file(s)", f"Files: {listed}")


def listing():
    """path -> blob id for every committed Markdown note."""
    out = {}
    for entry in git("ls-files", "-s", "-z").split("\0"):
        if not entry:
            continue
        meta, path = entry.split("\t", 1)
        mode, blob, _ = meta.split(" ")
        if mode in ("100644", "100755") and path.endswith(".md") and not any(p.startswith(".") for p in path.split("/")):
            out[path] = blob
    return out


# Paths ----------------------------------------------------------------------

def clean_path(p, note=True):
    """A vault-relative path, checked; Refused otherwise."""
    if not isinstance(p, str) or (note and not p.strip()):
        raise Refused("path is a note's path in the vault, like `inbox/idea.md`")
    p = unicodedata.normalize("NFC", p.strip().strip("/") if not note else p.strip())
    if not p and not note:
        return ""
    if len(p.encode()) > MAX_PATH_BYTES:
        raise Refused("that path is too long")
    if p.startswith("/") or any(ord(c) < 32 or ord(c) == 127 for c in p) or BAD_CHARS & set(p):
        raise Refused(f"{p!r} isn't a path this vault takes: no leading /, no control characters and none of "
                      "* \" < > : | ? # ^ [ ] \\")
    for part in p.split("/"):
        if not part or part in (".", "..") or part.startswith(".") or part.endswith((" ", ".")) \
                or len(part.encode()) > MAX_PART_BYTES:
            raise Refused(f"{p!r} isn't a path this vault takes: no empty, . or .. parts, nothing starting with "
                          "a dot, and nothing ending in a space or a dot")
    if note and not p.endswith(".md"):
        raise Refused(f"{p!r} isn't a note: notes end in .md")
    full = VAULT
    for part in p.split("/"):
        full = full / part
        try:
            info = os.lstat(full)
        except FileNotFoundError:
            break
        if stat.S_ISLNK(info.st_mode):
            raise Refused(f"{p!r} goes through a symbolic link, which this service doesn't follow")
    if not os.path.realpath(VAULT / p).startswith(os.path.realpath(VAULT) + os.sep):
        raise Refused(f"{p!r} is outside the vault")
    return p


def check_new_path(p, notes):
    if p in notes or (VAULT / p).exists():
        raise Refused(f"{p} already exists")
    lower = {q.lower(): q for q in notes}
    if p.lower() in lower:
        raise Refused(f"{lower[p.lower()]} already exists, differing only in case; Justin's Macs would see one note")
    folders = {}
    for q in notes:
        parts = q.split("/")[:-1]
        for i in range(1, len(parts) + 1):
            folder = "/".join(parts[:i])
            folders.setdefault(folder.lower(), folder)
    parts = p.split("/")[:-1]
    for i in range(1, len(parts) + 1):
        folder = "/".join(parts[:i])
        if folders.get(folder.lower(), folder) != folder:
            raise Refused(f"use the existing folder {folders[folder.lower()]}/ (it differs from {folder}/ only in case)")


def read_text(p):
    full = VAULT / p
    info = os.lstat(full)
    if not stat.S_ISREG(info.st_mode):
        raise Refused(f"{p} isn't a note")
    if info.st_size > MAX_READ_BYTES:
        raise Refused(f"{p} is {info.st_size:,} bytes, too big to read")
    return full.read_bytes().decode("utf-8", "replace")


def write_text(p, text):
    data = text.encode("utf-8")
    if len(data) > MAX_NOTE_BYTES:
        raise Refused(f"a note can be at most {MAX_NOTE_BYTES:,} bytes; this would be {len(data):,}")
    full = VAULT / p
    full.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, tmp = tempfile.mkstemp(prefix=".notes-", suffix=".tmp", dir=full.parent)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.chmod(tmp, 0o600)
        os.replace(tmp, full)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


# Parsing ----------------------------------------------------------------------

FENCE = re.compile(r"^\s*(```|~~~)")
HEADING = re.compile(r"^(#{1,6})[ \t]+(.+?)[ \t]*#*[ \t]*$")
TAG = re.compile(r"(?<![\w&/#\[\]`])#([A-Za-z0-9_/-]*[A-Za-z_/-][A-Za-z0-9_/-]*)")
WIKILINK = re.compile(r"(!?)\[\[([^\[\]|#^\n]*)(#[^\[\]|\n]*)?(?:\|([^\[\]\n]*))?\]\]")
MDLINK = re.compile(r"(?<!!)\[([^\]\n]*)\]\(<?([^)<>\s]+?\.md)(#[^)\s>]*)?>?\)")
INLINE_CODE = re.compile(r"`[^`\n]*`")


def frontmatter(text):
    """(fields, body start line): the simple top-level fields of a YAML front matter block."""
    lines = text.split("\n")
    if not lines or lines[0].strip() != "---":
        return {}, 0
    for end in range(1, min(len(lines), 400)):
        if lines[end].strip() in ("---", "..."):
            break
    else:
        return {}, 0
    fields, key = {}, None
    for line in lines[1:end]:
        item = re.match(r"^\s+-\s+(.*)$", line)
        if item and key:
            if not isinstance(fields[key], list):
                fields[key] = [] if fields[key] == "" else [fields[key]]
            fields[key].append(item.group(1).strip().strip("'\""))
            continue
        pair = re.match(r"^([A-Za-z0-9_-]+):\s*(.*)$", line)
        if not pair:
            continue
        key, value = pair.group(1), pair.group(2).strip()
        if value.startswith("[") and value.endswith("]"):
            fields[key] = [v.strip().strip("'\"") for v in value[1:-1].split(",") if v.strip()]
        else:
            fields[key] = value.strip("'\"")
    return fields, end + 1


def as_list(value):
    if isinstance(value, list):
        return [str(v) for v in value if str(v).strip()]
    return [v for v in re.split(r"[,\s]+", str(value or "")) if v]


def parse(p, text):
    fields, body_start = frontmatter(text)
    tags = {t.lstrip("#") for t in as_list(fields.get("tags", fields.get("tag")))}
    raw = fields.get("aliases", fields.get("alias"))
    aliases = [str(a) for a in raw] if isinstance(raw, list) else [a.strip() for a in str(raw or "").split(",") if a.strip()]
    headings, links, fenced = [], [], False
    for n, line in enumerate(text.split("\n"), 1):
        if n <= body_start:
            continue
        if FENCE.match(line):
            fenced = not fenced
            continue
        if fenced:
            continue
        h = HEADING.match(line)
        if h:
            headings.append({"level": len(h.group(1)), "text": h.group(2), "line": n})
        plain = INLINE_CODE.sub("", line)
        if not h:
            tags |= set(TAG.findall(plain))
        for m in WIKILINK.finditer(plain):
            links.append({"target": m.group(2).strip() or None, "heading": (m.group(3) or "")[1:] or None,
                          "embed": bool(m.group(1)), "line": n, "text": line.strip(), "kind": "wiki"})
        for m in MDLINK.finditer(plain):
            target = urllib.parse.unquote(m.group(2))
            if "://" in target:
                continue
            links.append({"target": target, "heading": (m.group(3) or "")[1:] or None, "embed": False,
                          "line": n, "text": line.strip(), "kind": "md"})
    return {"title": posixpath.basename(p)[:-3], "fields": fields, "tags": sorted(tags, key=str.lower),
            "aliases": aliases, "headings": headings, "links": links}


class Index:
    """Parsed notes, by blob id, so a note is parsed once per version."""

    def __init__(self):
        self.by_blob = {}
        self.notes = {}

    def refresh(self):
        self.notes = listing()
        live = set(self.notes.values())
        self.by_blob = {b: m for b, m in self.by_blob.items() if b in live}
        return self.notes

    def meta(self, p):
        blob = self.notes[p]
        if blob not in self.by_blob:
            try:
                size = os.lstat(VAULT / p).st_size
                text = read_text(p) if size <= MAX_INDEX_BYTES else ""
            except (OSError, Refused):
                text = ""
            meta = parse(p, text)
            meta["text"] = text
            meta["lower"] = text.lower()
            self.by_blob[blob] = meta
        return self.by_blob[blob]

    def resolve(self, target, from_path=None, kind="wiki"):
        """The note a link points at, as Obsidian would find it, or None."""
        if not target:
            return from_path
        t = target.strip()
        if kind == "md" and from_path:
            t = posixpath.normpath(posixpath.join(posixpath.dirname(from_path), t))
        if not t.lower().endswith(".md"):
            t += ".md"
        if t in self.notes:
            return t
        tl = t.lower()
        matches = [q for q in self.notes if q.lower() == tl or q.lower().endswith("/" + tl)]
        if not matches:
            return None
        here = posixpath.dirname(from_path or "")
        return sorted(matches, key=lambda q: (posixpath.dirname(q) != here, q.count("/"), q))[0]

    def find(self, path_or_link):
        if isinstance(path_or_link, str) and path_or_link.strip().endswith(".md"):
            p = clean_path(path_or_link)
            if p in self.notes:
                return p
        target = str(path_or_link or "").strip()
        if target.startswith("[[") and target.endswith("]]"):
            target = target[2:-2]
        target = target.split("|")[0].split("#")[0]
        found = self.resolve(target) if target else None
        if not found:
            raise Refused(f"there's no note at {path_or_link!r}; search_notes or list_notes finds one")
        return found


INDEX = Index()


# Requests ----------------------------------------------------------------------

def text_arg(value, name, limit, empty=False):
    if not isinstance(value, str) or (not empty and not value.strip()):
        raise Refused(f"{name} is text" + ("" if empty else ", and can't be empty"))
    if len(value.encode()) > limit:
        raise Refused(f"{name} can be at most {limit:,} bytes")
    return value


def int_arg(value, name, low, high):
    if not isinstance(value, int) or isinstance(value, bool) or not low <= value <= high:
        raise Refused(f"{name} is a whole number from {low:,} to {high:,}")
    return value


def message_arg(value):
    value = text_arg(value, "message", 1000)
    value = " ".join(value.split())
    if len(value) > MAX_MESSAGE:
        raise Refused(f"message is one line of at most {MAX_MESSAGE} characters: what changed and why")
    refuse_secrets(value, "message")
    return value


def iso_mtime(p):
    try:
        return datetime.datetime.fromtimestamp(os.lstat(VAULT / p).st_mtime, datetime.timezone.utc) \
            .strftime("%Y-%m-%dT%H:%M:%SZ")
    except OSError:
        return None


def last_change(p, rev="HEAD"):
    if not has_head():
        return None
    out = git("log", "-1", "--format=%H%x1f%an%x1f%aI", rev, "--", p).strip()
    if not out:
        return None
    commit_id, author, date = out.split("\x1f")
    return {"commit": commit_id, "author": author, "date": date}


def snippet(line):
    text, _ = redact(line.strip())
    return text[:200]


def search_notes(agent, query="", tag="", folder="", limit=10):
    query = text_arg(query, "query", 500, empty=True)
    tag = text_arg(tag, "tag", 200, empty=True).lstrip("#").lower()
    folder = clean_path(folder, note=False) if folder else ""
    limit = int_arg(limit, "limit", 1, 50)
    terms = [(a or b).lower() for a, b in re.findall(r'"([^"]+)"|(\S+)', query)]
    if not terms and not tag:
        raise Refused("give a query, a tag, or both")
    found = []
    for p in INDEX.notes:
        if folder and not p.startswith(folder + "/"):
            continue
        m = INDEX.meta(p)
        tags = [t.lower() for t in m["tags"]]
        if tag and not any(t == tag or t.startswith(tag + "/") for t in tags):
            continue
        title, aliases = m["title"].lower(), " ".join(m["aliases"]).lower()
        heads = " ".join(h["text"] for h in m["headings"]).lower()
        path_l = p.lower()
        score = 0
        for term in terms:
            body = m["lower"].count(term)
            if not (body or term in title or term in aliases or term in path_l or term in " ".join(tags)):
                break
            score += 10 * (term in title) + 6 * (term in aliases) + 4 * (term in heads) + 3 * (term in tags) \
                + 2 * (term in path_l) + min(body, 5)
        else:
            found.append((score, os.lstat(VAULT / p).st_mtime if (VAULT / p).exists() else 0, p, m))
    found.sort(key=lambda f: (-f[0], -f[1], f[2]))
    results = []
    for score, _, p, m in found[:limit]:
        snippets = []
        for n, line in enumerate(m["text"].split("\n"), 1):
            if terms and any(t in line.lower() for t in terms):
                snippets.append({"line": n, "text": snippet(line)})
                if len(snippets) == 3:
                    break
        results.append({"path": p, "title": m["title"], "tags": m["tags"], "score": score, "snippets": snippets})
    return {"results": results, "total": len(found), "truncated": len(found) > limit}


def read_note(agent, path="", start_line=1, max_chars=30_000, revision=""):
    start_line = int_arg(start_line, "start_line", 1, 10_000_000)
    max_chars = int_arg(max_chars, "max_chars", 1_000, 60_000)
    revision = text_arg(revision, "revision", 64, empty=True).strip()
    if revision:
        if not re.fullmatch(r"[0-9a-f]{7,40}", revision):
            raise Refused("revision is a commit id from note_history")
        p = clean_path(path) if str(path).endswith(".md") else INDEX.find(path)
        shown = git("show", f"{revision}:{p}", check=False, raw=True)
        if shown.returncode != 0:
            raise Refused(f"{p} didn't exist at {revision}")
        text = shown.stdout.decode("utf-8", "replace")
        blob = git("rev-parse", f"{revision}:{p}").strip()
        change = last_change(p, revision)
    else:
        p = INDEX.find(path)
        text, blob, change = read_text(p), INDEX.notes[p], last_change(p)
    meta = parse(p, text)
    lines = text.split("\n")
    out, size, end = [], 0, start_line - 1
    for line in lines[start_line - 1:]:
        if size + len(line) + 1 > max_chars and out:
            break
        out.append(line[:max_chars])
        size += len(line) + 1
        end += 1
    content, hidden = redact("\n".join(out))
    fields = {k: (redact(v)[0] if isinstance(v, str) else [redact(x)[0] for x in v]) for k, v in meta["fields"].items()}
    links = []
    for link in meta["links"][:200]:
        links.append({"target": link["target"], "heading": link["heading"],
                      "path": INDEX.resolve(link["target"], p, link["kind"])})
    return {"path": p, "title": meta["title"], "revision": blob, "last_change": change, "frontmatter": fields,
            "tags": meta["tags"], "aliases": meta["aliases"], "headings": meta["headings"], "links_out": links,
            "content": content, "start_line": start_line, "end_line": end, "total_lines": len(lines),
            "truncated": end < len(lines), "redacted": hidden}


def list_notes(agent, folder="", recursive=False, sort="name", limit=200):
    folder = clean_path(folder, note=False) if folder else ""
    if not isinstance(recursive, bool):
        raise Refused("recursive is true or false")
    if sort not in ("name", "recent"):
        raise Refused('sort is "name" or "recent"')
    limit = int_arg(limit, "limit", 1, 500)
    prefix = folder + "/" if folder else ""
    notes, folders = [], set()
    for p in INDEX.notes:
        if not p.startswith(prefix):
            continue
        rest = p[len(prefix):]
        if "/" in rest and not recursive:
            folders.add(prefix + rest.split("/")[0])
            continue
        try:
            size = os.lstat(VAULT / p).st_size
        except OSError:
            size = None
        notes.append({"path": p, "title": posixpath.basename(p)[:-3], "bytes": size, "changed": iso_mtime(p)})
    if folder and not notes and not folders:
        raise Refused(f"there's no folder {folder}/ with notes in it")
    notes.sort(key=(lambda n: n["path"].lower()) if sort == "name" else (lambda n: n["changed"] or ""),
               reverse=sort == "recent")
    return {"folder": folder, "folders": sorted(folders, key=str.lower), "notes": notes[:limit],
            "total": len(notes), "truncated": len(notes) > limit}


def backlinks(agent, path=""):
    p = INDEX.find(path)
    out = []
    for q in sorted(INDEX.notes):
        if q == p:
            continue
        m = INDEX.meta(q)
        for link in m["links"]:
            if link["target"] and INDEX.resolve(link["target"], q, link["kind"]) == p:
                out.append({"path": q, "title": m["title"], "line": link["line"], "text": snippet(link["text"])})
                if len(out) >= 200:
                    return {"path": p, "backlinks": out, "truncated": True}
    return {"path": p, "backlinks": out, "truncated": False}


def note_history(agent, path="", limit=10):
    p = clean_path(path) if str(path).strip().endswith(".md") else INDEX.find(path)
    limit = int_arg(limit, "limit", 1, 50)
    if not has_head():
        return {"path": p, "history": []}
    out = git("log", "--follow", f"-n{limit}", "--name-status", "--format=%x1e%H%x1f%an%x1f%aI%x1f%s", "--", p)
    history = []
    for chunk in out.split("\x1e")[1:]:
        lines = [line for line in chunk.split("\n") if line]
        commit_id, author, date, subject = lines[0].split("\x1f", 3)
        change, at = "modified", p
        for line in lines[1:]:
            parts = line.split("\t")
            at = parts[-1]
            if parts[0].startswith("A"):
                change = "added"
            elif parts[0].startswith("D"):
                change = "deleted"
            elif parts[0].startswith("R") and len(parts) == 3:
                change = f"moved from {parts[1]}"
        # path is where the note was at that commit, which read_note needs with the commit as its revision.
        history.append({"commit": commit_id, "path": at, "author": author, "date": date, "message": subject,
                        "change": change})
    return {"path": p, "history": history}


# Writes ------------------------------------------------------------------------

WRITES = collections.defaultdict(collections.deque)


def count_write(agent):
    now = time.monotonic()
    times = WRITES[agent]
    while times and now - times[0] > 3600:
        times.popleft()
    if len(times) >= WRITES_PER_HOUR:
        raise Refused(f"{agent} has made {WRITES_PER_HOUR} changes to the vault in the last hour, the most it may; "
                      "try again later")
    times.append(now)


def author_of(agent):
    return (f"{agent.capitalize()} (agent)", f"hermes-{agent}@agents.invalid")


def save(agent, tool, paths, message):
    commit_id = commit(paths, author_of(agent), message, f"Agent: {agent}\nTool: {tool}")
    INDEX.refresh()
    return commit_id


def written(p, commit_id):
    return {"path": p, "revision": INDEX.notes.get(p), "commit": commit_id}


def create_note(agent, path="", content="", message=""):
    p = clean_path(path)
    content = text_arg(content, "content", MAX_NOTE_BYTES, empty=True)
    message = message_arg(message)
    check_new_path(p, INDEX.notes)
    refuse_secrets(p, "path")
    refuse_secrets(content, "content")
    count_write(agent)
    write_text(p, content if content.endswith("\n") or not content else content + "\n")
    return written(p, save(agent, "create_note", [p], message))


def section_end(lines, heading):
    """The index after the end of the section under heading (a heading's text, with or without #s)."""
    want = heading.strip().lstrip("#").strip().lower()
    fenced, start, level = False, None, None
    for i, line in enumerate(lines):
        if FENCE.match(line):
            fenced = not fenced
            continue
        h = None if fenced else HEADING.match(line)
        if not h:
            continue
        if start is None and h.group(2).strip().lower() == want:
            start, level = i, len(h.group(1))
        elif start is not None and len(h.group(1)) <= level:
            return i
    if start is None:
        return None
    return len(lines)


def append_to_note(agent, path="", text="", message="", heading="", create=False):
    text = text_arg(text, "text", MAX_INSERT)
    message = message_arg(message)
    heading = text_arg(heading, "heading", 300, empty=True)
    if not isinstance(create, bool):
        raise Refused("create is true or false")
    refuse_secrets(text, "text")
    addition = text.strip("\n")
    try:
        p = INDEX.find(path)
    except Refused:
        if not create:
            raise
        p = clean_path(path)
        check_new_path(p, INDEX.notes)
        refuse_secrets(p, "path")
        count_write(agent)
        body = (f"## {heading.strip().lstrip('#').strip()}\n\n" if heading.strip() else "") + addition + "\n"
        write_text(p, body)
        return written(p, save(agent, "append_to_note", [p], message))
    current = read_text(p)
    if heading.strip():
        lines = current.split("\n")
        end = section_end(lines, heading)
        if end is None:
            names = ", ".join(h["text"] for h in parse(p, current)["headings"][:20]) or "none"
            raise Refused(f"{p} has no heading {heading!r} (its headings: {names})")
        before = lines[:end]
        while before and not before[-1].strip():
            before.pop()
        after = lines[end:]
        new = "\n".join(before + ["", addition] + ([""] + after if after else [""]))
    else:
        new = (current.rstrip("\n") + "\n\n" if current.strip() else "") + addition + "\n"
    count_write(agent)
    write_text(p, new)
    return written(p, save(agent, "append_to_note", [p], message))


def replace_in_note(agent, path="", old="", new="", message="", replace_all=False):
    p = INDEX.find(path)
    old = text_arg(old, "old", MAX_INSERT)
    new = text_arg(new, "new", MAX_INSERT, empty=True)
    message = message_arg(message)
    if not isinstance(replace_all, bool):
        raise Refused("replace_all is true or false")
    refuse_secrets(new, "new")
    current = read_text(p)
    count = current.count(old)
    if count == 0:
        raise Refused(f"{p} doesn't contain that text; old has to match exactly, whitespace included (read the note again)")
    if count > 1 and not replace_all:
        raise Refused(f"that text is in {p} {count} times; give more of it so it's unique, or set replace_all")
    count_write(agent)
    write_text(p, current.replace(old, new) if replace_all else current.replace(old, new, 1))
    return {**written(p, save(agent, "replace_in_note", [p], message)), "replaced": count if replace_all else 1}


def rewrite_note(agent, path="", content="", revision="", message=""):
    p = INDEX.find(path)
    content = text_arg(content, "content", MAX_NOTE_BYTES, empty=True)
    revision = text_arg(revision, "revision", 64)
    message = message_arg(message)
    if revision != INDEX.notes[p]:
        raise Refused(f"{p} changed since you read it (it's at revision {INDEX.notes[p]} now): read it again and "
                      "redo your change on what's there")
    old_lines = set(read_text(p).split("\n"))
    added = "\n".join(line for line in content.split("\n") if line not in old_lines)
    refuse_secrets(added, "content")
    if MARKER in content:
        refuse_secrets(content, "content")
    count_write(agent)
    write_text(p, content if content.endswith("\n") or not content else content + "\n")
    return written(p, save(agent, "rewrite_note", [p], message))


def link_target(p, notes):
    """How a wikilink names p: its title when that's unique, else its path without .md."""
    title = posixpath.basename(p)[:-3].lower()
    same = [q for q in notes if posixpath.basename(q)[:-3].lower() == title]
    return posixpath.basename(p)[:-3] if same == [p] else p[:-3]


def move_note(agent, path="", new_path="", message="", update_links=True):
    p = INDEX.find(path)
    target = clean_path(new_path)
    message = message_arg(message)
    if not isinstance(update_links, bool):
        raise Refused("update_links is true or false")
    check_new_path(target, INDEX.notes)
    refuse_secrets(target, "new_path")
    linkers = []
    if update_links:
        for q in INDEX.notes:
            if q != p and any(link["target"] and INDEX.resolve(link["target"], q, link["kind"]) == p
                              for link in INDEX.meta(q)["links"]):
                linkers.append(q)
        if len(linkers) > MAX_LINK_UPDATES:
            raise Refused(f"{len(linkers)} notes link to {p}, more than the {MAX_LINK_UPDATES} a move updates; "
                          "move it with update_links false, or ask Justin")
    count_write(agent)
    (VAULT / target).parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.rename(VAULT / p, VAULT / target)
    after = {**{q: b for q, b in INDEX.notes.items() if q != p}, target: INDEX.notes[p]}
    wiki_name = link_target(target, after)
    updated = []
    for q in linkers:
        q_now = target if q == p else q
        text = read_text(q_now)

        def wiki(m, q=q):
            if not m.group(2).strip() or INDEX.resolve(m.group(2).strip(), q, "wiki") != p:
                return m.group(0)
            alias = f"|{m.group(4)}" if m.group(4) is not None else ""
            return f"{m.group(1)}[[{wiki_name}{m.group(3) or ''}{alias}]]"

        def md(m, q=q):
            raw = urllib.parse.unquote(m.group(2))
            if "://" in raw or INDEX.resolve(raw, q, "md") != p:
                return m.group(0)
            rel = posixpath.relpath(target, posixpath.dirname(q) or ".")
            rel = urllib.parse.quote(rel) if "%" in m.group(2) else rel
            return f"[{m.group(1)}]({rel}{m.group(3) or ''})"

        new = MDLINK.sub(md, WIKILINK.sub(wiki, text))
        if new != text:
            write_text(q_now, new)
            updated.append(q_now)
    commit_id = save(agent, "move_note", [p, target] + updated, message)
    return {**written(target, commit_id), "moved_from": p, "links_updated": updated}


OPS = {f.__name__: f for f in (search_notes, read_note, list_notes, backlinks, note_history,
                                create_note, append_to_note, replace_in_note, rewrite_note, move_note)}
LOCK = threading.Lock()


def handle(agent, request):
    if not isinstance(request, dict) or request.get("op") not in OPS:
        raise Refused(f"unknown request; the operations are {', '.join(OPS)}")
    args = request.get("args") or {}
    if not isinstance(args, dict):
        raise Refused("args is an object")
    fn = OPS[request["op"]]
    with LOCK:
        settle()
        INDEX.refresh()
        try:
            return fn(agent, **args)
        except TypeError as err:
            raise Refused(f"{request['op']} doesn't take those arguments ({err})") from None


# Server ------------------------------------------------------------------------

def agents_by_uid():
    out = {}
    for entry in os.environ.get("NOTES_AGENTS", "").split(","):
        if "=" in entry:
            uid, name = entry.split("=", 1)
            out[int(uid)] = name.strip()
    return out


def status(**fields):
    path = STATE_DIR / "status.json"
    try:
        current = json.loads(path.read_text())
    except (OSError, ValueError):
        current = {}
    current.update(fields)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(current, indent=1))
    os.chmod(tmp, 0o600)
    tmp.replace(path)


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def serve_one(conn, agents):
    try:
        conn.settimeout(DEADLINE)
        pid, uid, gid = struct.unpack("3i", conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))
        agent = agents.get(uid)
        # Read the request even from a caller that's refused: closing with it
        # unread would reset the connection before the reply arrives.
        data = b""
        while not data.endswith(b"\n") and len(data) <= MAX_REQUEST:
            chunk = conn.recv(65536)
            if not chunk:
                break
            data += chunk
        if agent is None:
            reply = {"ok": False, "error": "this caller isn't one of the agents, so the vault refuses it"}
        else:
            try:
                if len(data) > MAX_REQUEST:
                    raise Refused("that request is too big")
                try:
                    request = json.loads(data.decode("utf-8"))
                except ValueError:
                    raise Refused("the request isn't JSON") from None
                reply = {"ok": True, "result": handle(agent, request)}
            except Refused as err:
                reply = {"ok": False, "error": str(err)}
            except Exception as err:  # noqa: BLE001 - the agent gets a reason, the journal the detail
                print(f"notes: {type(err).__name__}: {err}", file=sys.stderr)
                reply = {"ok": False, "error": "the vault service hit an error; nothing was changed by this request"}
        conn.sendall(json.dumps(reply, ensure_ascii=False).encode("utf-8") + b"\n")
    except (OSError, socket.timeout):
        pass
    finally:
        conn.close()


def watch():
    while True:
        time.sleep(WATCH_SECONDS)
        try:
            with LOCK:
                settle()
                notes = len(INDEX.refresh())
            status(last_ok=now_iso(), notes=notes)
        except Exception as err:  # noqa: BLE001 - keep watching; status says what went wrong
            print(f"notes: watching the vault: {err}", file=sys.stderr)
            status(last_error=str(err)[:300], last_error_at=now_iso())


def listener():
    if os.environ.get("LISTEN_FDS") == "1" and os.environ.get("LISTEN_PID") == str(os.getpid()):
        return socket.socket(fileno=3)
    path = os.environ["NOTES_LISTEN"]
    if os.path.exists(path):
        os.unlink(path)
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.bind(path)
    os.chmod(path, 0o660)
    sock.listen(16)
    return sock


def main():
    os.umask(0o077)
    agents = agents_by_uid()
    init_repo()
    with LOCK:
        settle()
        INDEX.refresh()
    status(started=now_iso(), last_ok=now_iso(), notes=len(INDEX.notes))
    threading.Thread(target=watch, daemon=True).start()
    sock = listener()
    while True:
        conn, _ = sock.accept()
        threading.Thread(target=serve_one, args=(conn, agents), daemon=True).start()


if __name__ == "__main__":
    main()
