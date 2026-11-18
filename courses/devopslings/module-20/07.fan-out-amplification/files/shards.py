"""profile shards, on :8221. GET /shard/<n> answers in about 10ms; one call in
a hundred, on any shard, takes 400ms instead (a compaction, a cold cache, a
noisy host — the reason changes, the rate does not)."""
import random
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        time.sleep(0.4 if random.random() < 0.01 else random.uniform(0.008, 0.012))
        body = b'{"ok":true}\n'
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


ThreadingHTTPServer.daemon_threads = True
ThreadingHTTPServer.request_queue_size = 1024
ThreadingHTTPServer(("0.0.0.0", 8221), H).serve_forever()
