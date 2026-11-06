"""orders — the order API. Serves GET /order on :8080.

It has no metrics of its own yet.
"""
import random
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def place_order():
    """Does the work. Raises when the order cannot be placed."""
    time.sleep(random.lognormvariate(-2.1, 0.6))  # median ~120ms, long tail
    if random.random() < 0.05:
        raise RuntimeError("payment provider declined")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path.split("?")[0] != "/order":
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        try:
            place_order()
            code, body = 200, b"ok\n"
        except RuntimeError:
            code, body = 500, b"error\n"
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


ThreadingHTTPServer.daemon_threads = True
ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
