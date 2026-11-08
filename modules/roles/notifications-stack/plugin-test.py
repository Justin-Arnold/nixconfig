#!/usr/bin/env python3
"""Tests the push plugin in the Python alertad runs with.

It checks that Alerta finds the plugin through its alerta.plugins entry
point and loads it from PLUGINS = ['push'], that every hook returns at once
and changes nothing, that the kicks reach a fake forwarder (status_change's
a second later, after Alerta has saved the status), and that a forwarder
that's down or hangs never raises or holds up the hook. For n8n it checks
that only an open alert that isn't a repeat is pushed, with its id and
nothing else, that nothing is pushed without N8N_ALERTS_URL, and that an
n8n that's down never holds up the hook.

usage: plugin-test.py
"""
import importlib.metadata
import logging
import socket
import sys
import threading
import time
import types
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

failures = []


def check(what, ok):
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        failures.append(what)


class Forwarder:
    def __init__(self):
        self.kicks = []
        self.hang = False
        forwarder = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):  # noqa: N802
                self.rfile.read(int(self.headers.get("Content-Length") or 0))
                if forwarder.hang:
                    time.sleep(3)
                forwarder.kicks.append((self.path, time.monotonic()))
                self.send_response(202)
                self.send_header("Content-Length", "0")
                self.end_headers()

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}/kick"


def until(test, seconds):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if test():
            return True
        time.sleep(0.02)
    return test()


def timed(call):
    start = time.monotonic()
    result = call()
    return result, time.monotonic() - start


warnings = []


class Collect(logging.Handler):
    def emit(self, record):
        warnings.append(record.getMessage())


logging.getLogger("alerta.plugins.push").addHandler(Collect(logging.WARNING))

found = [ep for ep in importlib.metadata.entry_points(group="alerta.plugins") if ep.name == "push"]
check("alerta.plugins has a `push` entry point", len(found) == 1 and found[0].value == "alerta_push:PushToForwarder")
from alerta.plugins import PluginBase  # noqa: E402

Push = found[0].load()
check("it's an Alerta plugin", issubclass(Push, PluginBase))

from flask import Flask  # noqa: E402

from alerta.utils.plugin import Plugins  # noqa: E402

app = Flask("test")
app.config["PLUGINS"] = ["push"]
plugins = Plugins()
plugins.register(app)
check("Alerta's own loader loads it from PLUGINS = ['push']", isinstance(plugins.plugins.get("push"), Push))

forwarder = Forwarder()
config = {"FORWARDER_KICK_URL": forwarder.url}
plugin = Push()
alert = types.SimpleNamespace(id="a1", severity="critical", status="open")

check("pre_receive passes the alert through untouched", plugin.pre_receive(alert, config=config) is alert)

result, took = timed(lambda: plugin.post_receive(alert, config=config))
check("post_receive returns at once and changes nothing", result is None and took < 0.2)
check("…and kicks the forwarder", until(lambda: len(forwarder.kicks) == 1, 1.0) and forwarder.kicks[0][0] == "/kick")

result, took = timed(lambda: plugin.post_action(alert, "ack", "ack operator action", timeout=None, config=config))
check("post_action returns at once, changes nothing, and kicks", result is None and took < 0.2
      and until(lambda: len(forwarder.kicks) == 2, 1.0))

asked = time.monotonic()
result, took = timed(lambda: plugin.status_change(alert, "closed", "closed by hand", config=config))
time.sleep(0.5)
check("status_change returns at once and holds its kick until the status is saved",
      result is None and took < 0.2 and len(forwarder.kicks) == 2)
check("…then kicks a second later", until(lambda: len(forwarder.kicks) == 3, 2.0) and forwarder.kicks[2][1] - asked >= 0.9)

check("a hook called the old way, without config, still works", plugin.post_receive(alert) is None)

closed = socket.socket()
closed.bind(("127.0.0.1", 0))
down = f"http://127.0.0.1:{closed.getsockname()[1]}/kick"
closed.close()
before = len(warnings)
result, took = timed(lambda: plugin.post_receive(alert, config={"FORWARDER_KICK_URL": down}))
check("a forwarder that's down doesn't fail or hold up the hook", result is None and took < 0.2)
check("…and it's logged as a warning", until(lambda: any(down in w for w in warnings[before:]), 2.0))

forwarder.hang = True
result, took = timed(lambda: plugin.post_receive(alert, config=config))
check("a forwarder that hangs doesn't hold up the hook", result is None and took < 0.2)
check("…and the kick gives up after a second", until(lambda: any("timed out" in w for w in warnings), 2.5))

forwarder.hang = False


class N8n:
    def __init__(self):
        self.bodies = []
        n8n = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):  # noqa: N802
                n8n.bodies.append(self.rfile.read(int(self.headers.get("Content-Length") or 0)))
                self.send_response(202)
                self.send_header("Content-Length", "0")
                self.end_headers()

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}/webhook/alerta"


n8n = N8n()
both = {"FORWARDER_KICK_URL": forwarder.url, "N8N_ALERTS_URL": n8n.url}
opened = types.SimpleNamespace(id="b1", severity="critical", status="open", repeat=False, text="ignore me")
kicks = len(forwarder.kicks)
result, took = timed(lambda: plugin.post_receive(opened, config=both))
check("an alert that opens is pushed to n8n, at once", result is None and took < 0.2
      and until(lambda: len(n8n.bodies) == 1, 1.0))
check("…with its id and nothing else", n8n.bodies and __import__("json").loads(n8n.bodies[0]) == {"id": "b1"})
check("…and the forwarder is still kicked", until(lambda: len(forwarder.kicks) == kicks + 1, 1.0))
plugin.post_receive(types.SimpleNamespace(id="b2", severity="critical", status="open", repeat=True), config=both)
plugin.post_receive(types.SimpleNamespace(id="b3", severity="cleared", status="closed", repeat=False), config=both)
plugin.post_receive(opened, config=config)
plugin.status_change(opened, "open", "reopened", config=both)
plugin.post_action(opened, "ack", "ack", timeout=None, config=both)
time.sleep(1.5)
check("a repeat, a closed alert, a status change, an action and a missing N8N_ALERTS_URL push nothing",
      len(n8n.bodies) == 1)
before = len(warnings)
result, took = timed(lambda: plugin.post_receive(opened, config={**both, "N8N_ALERTS_URL": down}))
check("an n8n that's down doesn't fail or hold up the hook", result is None and took < 0.2)
check("…and it's logged as a warning", until(lambda: any("couldn't tell n8n" in w for w in warnings[before:]), 4.0))

n8n.server.shutdown()
forwarder.server.shutdown()
if failures:
    sys.exit(f"{len(failures)} check(s) failed")
print("all checks passed")
