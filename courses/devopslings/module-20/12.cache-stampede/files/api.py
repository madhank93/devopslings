"""catalog API, on :8230. GET /product/<id> answers from cache.get, which is
answers/cache.py; on a miss cache.get calls load(), which queries catalog-db.
GET /warm loads every product once, all at the same moment."""
import json
import sys
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import cache

PRODUCTS = 20


def load(key):
    with urllib.request.urlopen(f"http://localhost:8231/product/{key}", timeout=10) as r:
        return json.loads(r.read())


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, body):
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/warm":
            ts = [threading.Thread(target=cache.get, args=(str(k), load)) for k in range(PRODUCTS)]
            for t in ts:
                t.start()
            for t in ts:
                t.join()
            return self.reply(200, b"warm\n")
        key = self.path.rsplit("/", 1)[-1]
        try:
            self.reply(200, (json.dumps(cache.get(key, load)) + "\n").encode())
        except urllib.error.HTTPError as e:
            self.reply(502, f"catalog-db: {e.code}\n".encode())
        except Exception as e:
            print(f"{key}: {e!r}", file=sys.stderr, flush=True)
            self.reply(500, f"{e!r}\n".encode())


ThreadingHTTPServer.daemon_threads = True
ThreadingHTTPServer.request_queue_size = 1024
ThreadingHTTPServer(("0.0.0.0", 8230), H).serve_forever()
