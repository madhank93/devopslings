"""render — the invoice renderer, on :8240. Each render waits about 200ms on the
PDF service. WORKERS renders run at once; requests beyond that queue."""
import os
import random
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

try:
    WORKERS = int(os.environ.get("WORKERS") or 8)
    assert WORKERS > 0
except (ValueError, AssertionError):
    sys.exit(f"WORKERS={os.environ.get('WORKERS')!r}: use a whole number above 0")
slots = threading.BoundedSemaphore(WORKERS)


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        with slots:
            time.sleep(random.uniform(0.12, 0.28))
        body = b"rendered\n"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


ThreadingHTTPServer.daemon_threads = True
ThreadingHTTPServer.request_queue_size = 4096
ThreadingHTTPServer(("0.0.0.0", 8240), H).serve_forever()
