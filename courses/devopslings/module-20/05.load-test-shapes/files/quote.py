"""quote — the shipping-quote service, on :8250.

16 quotes run at once, about 50ms each; up to 64 more wait, and beyond that it
answers 503. Duplicate requests are filtered per second: each second that sees
traffic gets its own 2MB filter, and old filters are only dropped once the
service has been idle for 2 seconds. The platform kills the process when its
resident memory passes 110MB; the loop deploy.sh starts it in restarts it."""
import json
import os
import random
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

WORKERS, QUEUE, FILTER, LIMIT_MB, IDLE = 16, 64, 2 << 20, 110, 2.0
slots = threading.BoundedSemaphore(WORKERS)
lock = threading.Lock()
waiting = 0
filters = {}
last_request = time.monotonic()


def rss_mb():
    with open("/proc/self/statm") as f:
        return int(f.read().split()[1]) * os.sysconf("SC_PAGE_SIZE") / 2**20


def housekeeping():
    while True:
        time.sleep(0.2)
        with lock:
            if time.monotonic() - last_request > IDLE:
                filters.clear()
        if rss_mb() > LIMIT_MB:
            print(f"quote: killed, resident memory {rss_mb():.0f}MB is over {LIMIT_MB}MB", flush=True)
            os._exit(137)


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def reply(self, code, body):
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        global waiting, last_request
        if self.path.startswith("/stats"):
            try:
                restarts = len(open("restarts").read().split())
            except OSError:
                restarts = 0
            return self.reply(200, json.dumps({"rss_mb": round(rss_mb()), "filters": len(filters),
                                               "restarts": restarts}).encode() + b"\n")
        with lock:
            last_request = time.monotonic()
            second = int(time.time())
            if second not in filters:
                filters[second] = bytearray(b"\1") * FILTER
            if waiting >= QUEUE:
                full = True
            else:
                full, waiting = False, waiting + 1
        if full:
            return self.reply(503, b"busy\n")
        with slots:
            with lock:
                waiting -= 1
            time.sleep(random.uniform(0.04, 0.06))
        self.reply(200, b"quoted\n")


ThreadingHTTPServer.daemon_threads = True
ThreadingHTTPServer.request_queue_size = 1024
threading.Thread(target=housekeeping, daemon=True).start()
print("quote: listening on :8250", flush=True)
ThreadingHTTPServer(("0.0.0.0", 8250), H).serve_forever()
