"""One of four services in a call chain, chosen by the first argument.

    gateway  /account   answered locally
             /product   -> product /product -> reviews
             /checkout  -> orders /checkout -> product /stock

reviews is the only dependency that ever gets slow. Every other service is
healthy: each has a fixed pool of worker threads, and a request waits for one
before it is handled.

A call to another service obeys two settings for that hop, read from the
environment as <CALLER>_TO_<CALLEE>_TIMEOUT (seconds, 0 = wait forever) and
<CALLER>_TO_<CALLEE>_POOL (calls in flight at once, 0 = no limit; a call that
finds the pool full fails at once).
"""

import json
import os
import random
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import requests

ROLE = sys.argv[1]
PORTS = {"reviews": 8110, "product": 8111, "orders": 8112, "gateway": 8113}
THREADS = {"reviews": 64, "product": 8, "orders": 8, "gateway": 16}[ROLE]
HOPS = {
    "gateway": {"product": "http://localhost:8111", "orders": "http://localhost:8112"},
    "orders": {"product": "http://localhost:8111"},
    "product": {"reviews": "http://toxiproxy:21110"},
    "reviews": {},
}[ROLE]
# A request that waits this long for a worker thread counts as starved.
STARVED_AFTER = 0.5


def knob(name, cast):
    raw = (os.environ.get(name) or "0").strip()
    try:
        value = cast(raw)
    except ValueError:
        sys.exit(f"{name}={raw!r} is not a number")
    if value < 0:
        sys.exit(f"{name}={raw!r} must be 0 or more")
    return value


timeouts, pools = {}, {}
for dep in HOPS:
    prefix = f"{ROLE.upper()}_TO_{dep.upper()}"
    timeouts[dep] = knob(f"{prefix}_TIMEOUT", float) or None
    size = knob(f"{prefix}_POOL", int)
    pools[dep] = threading.BoundedSemaphore(size) if size else None

workers = threading.Semaphore(THREADS)
lock = threading.Lock()
stats = {"requests": 0, "starved": 0}


class Failed(Exception):
    pass


def call(dep, path):
    pool = pools[dep]
    if pool is not None and not pool.acquire(blocking=False):
        raise Failed(f"{dep} pool full")
    try:
        r = requests.get(HOPS[dep] + path, timeout=timeouts[dep])
        r.raise_for_status()
        return r.json()
    except requests.RequestException as exc:
        raise Failed(f"{dep}: {type(exc).__name__}") from exc
    finally:
        if pool is not None:
            pool.release()


def handle(route):
    if ROLE == "reviews" and route == "/reviews":
        # Most lookups are quick; one in ten is a product with a long history.
        time.sleep(0.3 if random.random() < 0.1 else 0.02)
        return 200, {"reviews": ["sturdy", "would buy again"]}
    if ROLE == "product" and route == "/stock":
        time.sleep(0.005)
        return 200, {"in_stock": True}
    if ROLE == "product" and route == "/product":
        try:
            reviews = call("reviews", "/reviews")["reviews"]
        except Failed:
            reviews = None  # the page renders without them
        return 200, {"name": "kettle", "reviews": reviews}
    if ROLE == "orders" and route == "/checkout":
        try:
            call("product", "/stock")
        except Failed as exc:
            return 503, {"error": str(exc)}
        return 200, {"order": "placed"}
    if ROLE == "gateway" and route == "/account":
        return 200, {"account": "ok"}
    if ROLE == "gateway" and route in ("/product", "/checkout"):
        dep = "product" if route == "/product" else "orders"
        try:
            return 200, call(dep, route)
        except Failed as exc:
            return 503, {"error": str(exc)}
    return 404, {"error": "no such route"}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except OSError:
            pass

    def do_GET(self):
        route = self.path.split("?")[0]
        if route == "/health":
            return self.reply(200, {"status": "ok"})
        if route == "/stats":
            with lock:
                return self.reply(200, dict(stats))
        queued = time.monotonic()
        with workers:
            waited = time.monotonic() - queued
            with lock:
                stats["requests"] += 1
                stats["starved"] += waited > STARVED_AFTER
            self.reply(*handle(route))

    def do_POST(self):
        if self.path == "/reset":
            with lock:
                stats.update(requests=0, starved=0)
        self.reply(200, {})


if __name__ == "__main__":
    print(f"{ROLE} up: threads={THREADS} timeouts={timeouts} "
          f"pools={ {d: bool(p) for d, p in pools.items()} }", flush=True)
    ThreadingHTTPServer.daemon_threads = True
    ThreadingHTTPServer.request_queue_size = 1024
    ThreadingHTTPServer(("0.0.0.0", PORTS[ROLE]), H).serve_forever()
