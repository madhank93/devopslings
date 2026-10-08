"""orders — one replica of the service behind the load balancer.

Two of these run as orders-a and orders-b. The load balancer polls /ready on
each and only sends traffic to replicas that answer 200.

/order does some work and answers. ?ms= sets how long the work takes; most
orders are quick, and an export can take several seconds.
"""

import signal
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

ready = threading.Event()
ready.set()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/ready":
            if ready.is_set():
                self.answer(200, b"ready\n")
            else:
                self.answer(503, b"draining\n")
        elif url.path == "/order":
            ms = int(parse_qs(url.query).get("ms", ["300"])[0])
            time.sleep(ms / 1000)
            self.answer(200, b"order placed\n")
        else:
            self.answer(404, b"not found\n")

    def answer(self, code, body):
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


# Longer than the balancer needs to notice /ready failing: one 500ms poll,
# plus slack for a slow check.
DRAIN_DELAY = 1.5


def drain():
    time.sleep(DRAIN_DELAY)  # still serving: requests already routed here land
    server.shutdown()        # then stop accepting


def on_sigterm(signum, frame):
    ready.clear()            # tell the balancer first
    threading.Thread(target=drain).start()


# The stdlib listen backlog is 5, which drops connections in a burst.
ThreadingHTTPServer.request_queue_size = 128
server = ThreadingHTTPServer(("0.0.0.0", 8080), Handler)
# Non-daemon handler threads are joined by server_close(), so in-flight
# requests finish before the process exits.
server.daemon_threads = False
signal.signal(signal.SIGTERM, on_sigterm)
print("orders up on :8080", flush=True)
server.serve_forever()
server.server_close()
