#!/usr/bin/env python3
import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PREVIEW_BASE = Path("/var/lib/pr-previews")
INSTANCES_DIR = PREVIEW_BASE / "instances"
PORT = 8405


def valid_instance_id(instance_id):
    parts = instance_id.split("-")
    return (
        len(parts) >= 3
        and parts[0] == "pr"
        and parts[1].isdigit()
        and all(part.replace("-", "").isalnum() for part in parts[2:])
    )


def instance_dir(instance_id):
    if not valid_instance_id(instance_id):
        return None
    return INSTANCES_DIR / instance_id


def read_state(path):
    state_file = path / "state.json"
    if not state_file.exists():
        return {"status": "not_found", "message": "Preview state was not found"}
    try:
        with state_file.open("r") as f:
            return json.load(f)
    except json.JSONDecodeError:
        return {"status": "unknown", "message": "Preview state could not be parsed"}


class LogStreamHandler(BaseHTTPRequestHandler):
    def _set_cors_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def _send_json(self, payload, code=200):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self._set_cors_headers()
        self.end_headers()
        self.wfile.write(json.dumps(payload).encode())

    def _send_sse(self, payload):
        data = f"data: {json.dumps(payload)}\n\n"
        self.wfile.write(data.encode())
        self.wfile.flush()

    def do_OPTIONS(self):
        self.send_response(200)
        self._set_cors_headers()
        self.end_headers()

    def do_GET(self):
        parts = [part for part in self.path.strip("/").split("/") if part]
        if len(parts) != 2 or parts[0] not in {"logs", "status"}:
            self.send_error(404)
            return

        action, instance_id = parts
        path = instance_dir(instance_id)
        if path is None:
            self._send_json({"status": "error", "message": "Invalid preview id"}, 400)
            return

        if action == "status":
            self._send_json(read_state(path))
            return

        self.stream_logs(path)

    def stream_logs(self, path):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.send_header("X-Accel-Buffering", "no")
        self._set_cors_headers()
        self.end_headers()

        deploy_log = path / "deploy.log"
        app_log = path / "app.log"
        offsets = {}

        try:
            self.wfile.write(b": stream-open\n\n")
            self.wfile.flush()
            self._send_sse({"state": read_state(path)})

            last_heartbeat = time.time()
            while True:
                emitted = False
                for label, log_file in (("deploy", deploy_log), ("app", app_log)):
                    if not log_file.exists():
                        continue

                    with log_file.open("r", errors="replace") as f:
                        f.seek(offsets.get(str(log_file), 0))
                        for line in f:
                            self._send_sse({"source": label, "line": line.rstrip()})
                            emitted = True
                        offsets[str(log_file)] = f.tell()

                state = read_state(path)
                status = state.get("status", "unknown")
                if status in {"ready", "failed", "cleaned"}:
                    self._send_sse({"state": state, "complete": status == "ready", "failed": status == "failed"})
                    break

                now = time.time()
                if not emitted and now - last_heartbeat >= 10:
                    self.wfile.write(b": keep-alive\n\n")
                    self.wfile.flush()
                    self._send_sse({"state": state})
                    last_heartbeat = now

                time.sleep(0.5)
        except BrokenPipeError:
            pass
        except ConnectionResetError:
            pass

    def log_message(self, format, *args):
        pass


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", PORT), LogStreamHandler)
    print(f"Log stream server listening on port {PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        server.shutdown()
