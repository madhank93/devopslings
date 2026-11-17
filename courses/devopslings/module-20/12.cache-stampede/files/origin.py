"""catalog-db, on :8231. GET /product/<id> takes about 150ms when it is quiet,
and 10ms longer for every other query running beside it. It has 30
connections: a query that arrives while 30 are running is refused with a 503.

GET /stats   {"calls", "refused", "peak_inflight"} since start or the last reset
POST /reset  zero the stats
"""
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LIMIT = 30
lock = threading.Lock()
stats = {"calls": 0, "refused": 0, "peak_inflight": 0}
inflight = 0


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, obj):
        body = (json.dumps(obj) + "\n").encode()
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        with lock:
            stats.update(calls=0, refused=0, peak_inflight=0)
        self.reply(200, stats)

    def do_GET(self):
        global inflight
        if self.path == "/stats":
            with lock:
                return self.reply(200, dict(stats))
        with lock:
            stats["calls"] += 1
            if inflight >= LIMIT:
                stats["refused"] += 1
                refused = True
            else:
                refused = False
                inflight += 1
                busy = inflight
                stats["peak_inflight"] = max(stats["peak_inflight"], inflight)
        if refused:
            return self.reply(503, {"error": "too many connections"})
        try:
            time.sleep(0.14 + 0.01 * busy)
            self.reply(200, {"id": self.path.rsplit("/", 1)[-1], "fetched_at": time.time()})
        finally:
            with lock:
                inflight -= 1


ThreadingHTTPServer.daemon_threads = True
ThreadingHTTPServer.request_queue_size = 1024
ThreadingHTTPServer(("0.0.0.0", 8231), H).serve_forever()
