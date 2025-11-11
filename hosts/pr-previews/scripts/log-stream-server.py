#!/usr/bin/env python3
import os
import time
import json
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path

LOG_DIR = "/var/lib/pr-previews/logs"
PORT = 8405

class LogStreamHandler(BaseHTTPRequestHandler):
    def _set_cors_headers(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
    
    def do_OPTIONS(self):
        self.send_response(200)
        self._set_cors_headers()
        self.end_headers()
    
    def do_GET(self):
        parts = self.path.strip('/').split('/')
        
        if len(parts) != 2:
            self.send_error(404)
            return
        
        action, pr_id = parts
        log_file = f"{LOG_DIR}/{pr_id}.log"
        status_file = f"/var/lib/pr-previews/{pr_id}/.deploy-status"
        
        if action == "status":
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self._set_cors_headers()
            self.end_headers()
            
            if os.path.exists(status_file):
                with open(status_file, 'r') as f:
                    status = f.read().strip()
            else:
                status = "deploying" if os.path.exists(log_file) else "not_found"
            
            response = {
                "status": status,
                "log_exists": os.path.exists(log_file)
            }
            self.wfile.write(json.dumps(response).encode())
            return
        
        elif action == "logs":
            if not os.path.exists(log_file):
                self.send_error(404, f"Log file not found - {pr_id} - {log_file}")
                return
            
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Cache-Control', 'no-cache')
            self.send_header('Connection', 'keep-alive')
            self._set_cors_headers()
            self.end_headers()
            
            try:
                with open(log_file, 'r') as f:
                    for line in f:
                        data = f"data: {json.dumps({'line': line.rstrip()})}\n\n"
                        self.wfile.write(data.encode())
                        self.wfile.flush()
                
                with open(log_file, 'r') as f:
                    f.seek(0, 2)
                    
                    while True:
                        line = f.readline()
                        if line:
                            data = f"data: {json.dumps({'line': line.rstrip()})}\n\n"
                            self.wfile.write(data.encode())
                            self.wfile.flush()
                        else:
                            if os.path.exists(status_file):
                                with open(status_file, 'r') as sf:
                                    if sf.read().strip() == "complete":
                                        data = f"data: {json.dumps({'complete': True})}\n\n"
                                        self.wfile.write(data.encode())
                                        self.wfile.flush()
                                        break
                            time.sleep(0.5)
            except BrokenPipeError:
                pass
            return
        
        else:
            self.send_error(404)
    
    def log_message(self, format, *args):
        pass

if __name__ == '__main__':
    server = HTTPServer(('0.0.0.0', PORT), LogStreamHandler)
    print(f"Log stream server listening on port {PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        server.shutdown()