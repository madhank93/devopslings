"""cart — the build under test, on :8210. BUILD picks which one runs.

healthy:   about 20ms a request, nothing fails.
regressed: one request in eight makes an extra round trip that costs 150ms,
           and one in fifty fails with a 500.
"""
import os
import random
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REGRESSED = os.environ.get("BUILD") == "regressed"


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        took = random.uniform(0.012, 0.030)
        code = 200
        if REGRESSED:
            if random.random() < 0.125:
                took += 0.150
            if random.random() < 0.02:
                code = 500
        time.sleep(took)
        body = (b"ok\n" if code == 200 else b"error\n")
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


ThreadingHTTPServer.daemon_threads = True
ThreadingHTTPServer(("0.0.0.0", 8210), H).serve_forever()
