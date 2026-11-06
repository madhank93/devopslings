"""sink — stands in for the pager. Records every webhook Alertmanager sends.

POST /<anything>   store the notification (the path names the receiver URL)
GET  /notifications  every notification so far, oldest first
POST /reset        forget them all
"""
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

lock = threading.Lock()
seen = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/notifications":
            with lock:
                self.reply(200, list(seen))
        else:
            self.reply(200, {"status": "ok"})

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if self.path == "/reset":
            with lock:
                seen.clear()
            return self.reply(200, {})
        try:
            payload = json.loads(body or b"{}")
        except ValueError:
            payload = {"raw": body.decode(errors="replace")}
        with lock:
            seen.append({"path": self.path, "at": time.time(), "payload": payload})
        alerts = ", ".join(a.get("labels", {}).get("alertname", "?") for a in payload.get("alerts", []))
        print(f"{time.strftime('%H:%M:%S')} {self.path} {payload.get('status')} [{alerts}]", flush=True)
        self.reply(200, {})


ThreadingHTTPServer.daemon_threads = True
ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
