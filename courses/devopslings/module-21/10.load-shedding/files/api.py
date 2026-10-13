"""api — two routes sharing a fixed amount of CPU.

Every request costs WORK seconds on one of CORES cores, whatever its route, so
the service can finish CORES / WORK requests a second and no more. Worker
threads only wait for a core: more of them add queue, not capacity.

Admission control runs the moment a request arrives, before it joins any
queue. In-flight counts every request that has been admitted and not yet
answered — queued or running.
"""

import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CORES, WORK = 2, 0.050  # 40 requests a second
LOW_PRIORITY = {"/recommendations"}


def knob(name, cast):
    raw = (os.environ.get(name) or "0").strip()
    try:
        value = cast(raw)
    except ValueError:
        sys.exit(f"{name}={raw!r} is not a number")
    if value < 0:
        sys.exit(f"{name}={raw!r} must be 0 or more")
    return value


WORKERS = knob("API_WORKERS", int) or 16
QUEUE_TIMEOUT = knob("QUEUE_TIMEOUT_MS", int) / 1000
SHED_ALL_AT = knob("SHED_ALL_AT", int)
SHED_LOW_AT = knob("SHED_LOW_AT", int)

workers = threading.Semaphore(WORKERS)
cores = threading.Semaphore(CORES)
lock = threading.Lock()
inflight = 0


def acquire(sem, deadline):
    if deadline is None:
        return sem.acquire()
    return sem.acquire(timeout=max(deadline - time.monotonic(), 0))


def serve(route):
    global inflight
    with lock:
        if SHED_ALL_AT and inflight >= SHED_ALL_AT:
            return 503, "shed: at SHED_ALL_AT"
        if route in LOW_PRIORITY and SHED_LOW_AT and inflight >= SHED_LOW_AT:
            return 503, "shed: at SHED_LOW_AT"
        inflight += 1
    try:
        deadline = time.monotonic() + QUEUE_TIMEOUT if QUEUE_TIMEOUT else None
        if not acquire(workers, deadline):
            return 503, "queue timeout waiting for a worker"
        try:
            if not acquire(cores, deadline):
                return 503, "queue timeout waiting for a core"
            try:
                time.sleep(WORK)
            finally:
                cores.release()
        finally:
            workers.release()
        return 200, "ok"
    finally:
        with lock:
            inflight -= 1


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        route = self.path.split("?")[0]
        if route == "/health":
            code, status = 200, "ok"
        elif route in ("/checkout", "/recommendations"):
            code, status = serve(route)
        else:
            code, status = 404, "no such route"
        data = json.dumps({"status": status}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except OSError:
            pass


if __name__ == "__main__":
    print(f"api up: workers={WORKERS} queue_timeout={QUEUE_TIMEOUT}s "
          f"shed_all_at={SHED_ALL_AT or 'off'} shed_low_at={SHED_LOW_AT or 'off'}", flush=True)
    ThreadingHTTPServer.daemon_threads = True
    ThreadingHTTPServer.request_queue_size = 1024
    ThreadingHTTPServer(("0.0.0.0", 8100), H).serve_forever()
