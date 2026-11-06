"""gateway — the payments gateway, a vendor product with no metrics endpoint.

GET /status on :8080 answers JSON with its lifetime counts and queue depth:
  {"payments": {"processed": N, "failed": N}, "queue_depth": N}
It logs each payment to /obs/logs/payments.log and rotates that file every
minute, keeping one old copy.

While /obs/run/gateway.slow exists, /status takes 8 seconds to answer, as it
does in production when the gateway is overloaded.
"""
import json
import os
import random
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = "/obs/logs/payments.log"
lock = threading.Lock()
# The vendor's counts run from installation, not from this process's start.
state = {"processed": 183402, "failed": 2117, "queue_depth": 0}


def work():
    log = open(LOG, "a", buffering=1)
    rotated = time.time()
    while True:
        time.sleep(random.uniform(0.1, 0.3))
        ok = random.random() >= 0.03
        with lock:
            state["processed" if ok else "failed"] += 1
            state["queue_depth"] = random.randint(0, 20)
        log.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} payment {random.getrandbits(32):08x} "
                  f"{'processed' if ok else 'failed'}\n")
        if time.time() - rotated >= 60:
            log.close()
            os.replace(LOG, LOG + ".1")
            log = open(LOG, "a", buffering=1)
            rotated = time.time()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path != "/status":
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if os.path.exists("/obs/run/gateway.slow"):
            time.sleep(8)
        with lock:
            body = json.dumps({"payments": {"processed": state["processed"], "failed": state["failed"]},
                               "queue_depth": state["queue_depth"]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


threading.Thread(target=work, daemon=True).start()
ThreadingHTTPServer.daemon_threads = True
ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
