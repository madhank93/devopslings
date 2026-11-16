"""broker — an in-memory queue between checkout and fulfil.

POST /publish   append the JSON body as one message
GET  /consume   take the oldest message (204 when the queue is empty)
GET  /peek      the last ten messages published, without consuming them
"""
import collections
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

lock = threading.Lock()
queue = collections.deque(maxlen=10000)
recent = collections.deque(maxlen=10)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, body=b""):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path != "/publish":
            return self.reply(404)
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        try:
            json.loads(body)
        except ValueError:
            return self.reply(400, b'{"error":"message is not JSON"}')
        with lock:
            queue.append(body)
            recent.append(body)
        self.reply(202)

    def do_GET(self):
        if self.path == "/consume":
            with lock:
                msg = queue.popleft() if queue else None
            return self.reply(200, msg) if msg else self.reply(204)
        if self.path == "/peek":
            with lock:
                msgs = [json.loads(m) for m in recent]
            return self.reply(200, json.dumps(msgs).encode())
        self.reply(404)


ThreadingHTTPServer.daemon_threads = True
ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
