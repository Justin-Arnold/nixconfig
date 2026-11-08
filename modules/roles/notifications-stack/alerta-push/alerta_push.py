"""Alerta server plugin `push`: tells the forwarder to read Alerta now.

Alerta has no outgoing notifications of its own, and alerta-apprise-forwarder
reads it to send them. This plugin POSTs an empty /kick to the forwarder
whenever an alert comes in, changes status, or has an action taken on it,
so the forwarder's read happens within a second instead of at its next
sweep. The kick carries nothing about the alert: the forwarder reads Alerta
for that, as it always did.

Each kick goes from its own thread with a one-second timeout, and every
error is caught and logged, so a forwarder that's down or slow never holds
up or fails Alerta's request. status_change runs before Alerta saves the new
status, so its kick waits a second.

The forwarder's address is FORWARDER_KICK_URL in alertad.conf or the
environment.

It also tells n8n, at N8N_ALERTS_URL, when an alert opens: a new alert, a
reopened one or one whose severity changed, never a repeat. n8n decides
whether the monitor triages it. That push carries only the alert's id, since
n8n reads the alert from Alerta itself, and it's sent the same way as the
kick: its own thread, a short timeout, errors logged and dropped. n8n's
sweep picks up anything a dropped push missed. Without N8N_ALERTS_URL there's
no push.
"""
import json
import logging
import threading
import urllib.request

from alerta.plugins import PluginBase

LOG = logging.getLogger("alerta.plugins.push")

KICK_URL = "http://127.0.0.1:9088/kick"
TIMEOUT = 1
# n8n is over the tunnel, with TLS, so it gets a little longer.
N8N_TIMEOUT = 3
# status_change runs before the new status is saved.
STATUS_DELAY = 1


def kick(url):
    try:
        request = urllib.request.Request(url, data=b"", method="POST")
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            response.read()
    except Exception as err:  # noqa: BLE001 - the forwarder's sweep catches up
        LOG.warning("couldn't kick the forwarder at %s: %s", url, err)


def push(url, alert_id):
    try:
        request = urllib.request.Request(url, data=json.dumps({"id": alert_id}).encode(), method="POST",
                                         headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=N8N_TIMEOUT) as response:
            response.read()
    except Exception as err:  # noqa: BLE001 - n8n's sweep catches up
        LOG.warning("couldn't tell n8n at %s about %s: %s", url, alert_id, err)


class PushToForwarder(PluginBase):

    def kick(self, delay=0, **kwargs):
        try:
            url = self.get_config("FORWARDER_KICK_URL", default=KICK_URL, type=str, **kwargs)
            timer = threading.Timer(delay, kick, args=(url,))
            timer.daemon = True
            timer.start()
        except Exception as err:  # noqa: BLE001 - never fail Alerta's request
            LOG.warning("couldn't start a kick: %s", err)

    def push(self, alert, **kwargs):
        try:
            url = self.get_config("N8N_ALERTS_URL", default="", type=str, **kwargs)
            if not url or getattr(alert, "repeat", False) or getattr(alert, "status", None) != "open":
                return
            thread = threading.Thread(target=push, args=(url, alert.id), daemon=True)
            thread.start()
        except Exception as err:  # noqa: BLE001 - never fail Alerta's request
            LOG.warning("couldn't start a push to n8n: %s", err)

    def pre_receive(self, alert, **kwargs):
        return alert

    def post_receive(self, alert, **kwargs):
        self.kick(**kwargs)
        self.push(alert, **kwargs)
        return None

    def status_change(self, alert, status, text, **kwargs):
        self.kick(delay=STATUS_DELAY, **kwargs)
        return None

    def post_action(self, alert, action, text, **kwargs):
        self.kick(**kwargs)
        return None
