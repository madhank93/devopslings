"""pricing, metered — run inside the pricing container on :8214.

Answers exactly like pricing (a price, or 404 for a retired SKU) and counts
every request that reaches it, per phase of the game day. These are the
dependency's own counters: what it received, not what shop says it sent.
"""

import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PHASES = ("steady", "rush", "outage", "after")
lock = threading.Lock()
arrivals = []      # (time, repeated_after_404)
answered_404 = {}  # request id -> when its 404 was sent
marks = {}


def phase_of(t):
    current = None
    for name in PHASES:
        if name in marks and t >= marks[name]:
            current = name
    return current


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, body):
        # One write: a response split across two chunks can straddle a change
        # of toxic, and a timeout mid-body reads as a connection error.
        data = json.dumps(body).encode()
        head = "HTTP/1.0 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n" % (
            code, "OK" if code == 200 else "Not Found", len(data))
        try:
            self.wfile.write(head.encode() + data)
        except OSError:
            pass

    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/price":
            rid, now = self.headers.get("X-Request-Id", ""), time.time()
            with lock:
                # Only steady-phase repeats count: there is no latency then, so a
                # 404 sent was a 404 delivered, and a repeat is a retried answer.
                repeat = rid in answered_404 and phase_of(answered_404[rid]) == "steady"
                arrivals.append((now, repeat))
            if parse_qs(u.query).get("sku", [""])[0] == "retired":
                with lock:
                    answered_404[rid] = time.time()
                self.reply(404, {"error": "unknown sku"})
            else:
                self.reply(200, {"price": 42.0})
        elif u.path == "/stats":
            with lock:
                received = dict.fromkeys(PHASES, 0)
                for t, _ in arrivals:
                    p = phase_of(t)
                    if p:
                        received[p] += 1
                self.reply(200, {"received": received,
                                 "repeated_after_404": sum(1 for _, r in arrivals if r)})
        else:
            self.reply(404, {})

    def do_POST(self):
        u = urlparse(self.path)
        with lock:
            if u.path == "/reset":
                arrivals.clear()
                answered_404.clear()
                marks.clear()
            elif u.path == "/mark":
                marks[parse_qs(u.query)["name"][0]] = time.time()
        self.reply(200, {})


ThreadingHTTPServer.daemon_threads = True
ThreadingHTTPServer.request_queue_size = 1024
ThreadingHTTPServer(("0.0.0.0", 8214), H).serve_forever()
