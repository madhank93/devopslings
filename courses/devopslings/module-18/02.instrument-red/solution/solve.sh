#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# RED for orders: a Counter labelled by status code (rate and errors), and a
# Histogram in seconds whose default buckets (5ms..10s) span its 30ms-2s
# latencies. Both are recorded for every request, failures included.
set -euo pipefail
cat > /obs/apps/orders.py <<'PY'
"""orders — the order API. Serves GET /order on :8080, metrics on :9101."""
import random
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from prometheus_client import Counter, Histogram, start_http_server

REQUESTS = Counter("orders_requests_total", "Order requests served, by HTTP status code.", ["code"])
DURATION = Histogram("orders_request_duration_seconds", "Time to serve an order request.")


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
        start = time.perf_counter()
        try:
            place_order()
            code, body = 200, b"ok\n"
        except RuntimeError:
            code, body = 500, b"error\n"
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        DURATION.observe(time.perf_counter() - start)
        REQUESTS.labels(str(code)).inc()


start_http_server(9101)
ThreadingHTTPServer.daemon_threads = True
ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
PY
