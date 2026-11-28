"""ledger-legacy — the old ledger API on :9480. GET /entries/<id> reads an
entry, POST /entries records one. No metrics, no tracing, no SDK."""
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


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
        if not self.path.startswith("/entries/"):
            return self.reply(404, {"error": "not found"})
        time.sleep(0.005)
        self.reply(200, {"id": self.path.rsplit("/", 1)[-1], "amount": 0})

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        time.sleep(0.01)
        self.reply(201, {"ok": True})


ThreadingHTTPServer.daemon_threads = True
ThreadingHTTPServer(("0.0.0.0", 9480), Handler).serve_forever()
