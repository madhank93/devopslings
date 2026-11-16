"""profile page, on :8220. Each page needs all ten shards.

FANOUT=sequential  calls shard 0, then shard 1, ... then shard 9
FANOUT=parallel    calls all ten at once and waits for the last
HEDGE_AFTER_MS=n   when a shard call has not answered after n ms, send the same
                   call again and take whichever answers first; 0 = never
"""
import os
import sys
import urllib.request
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SHARDS = 10
FANOUT = (os.environ.get("FANOUT") or "sequential").strip()
try:
    HEDGE = float(os.environ.get("HEDGE_AFTER_MS") or 0) / 1000
except ValueError:
    sys.exit(f"HEDGE_AFTER_MS={os.environ.get('HEDGE_AFTER_MS')!r} is not a number")
if FANOUT not in ("sequential", "parallel"):
    sys.exit(f"FANOUT={FANOUT!r}: use sequential or parallel")

pool = ThreadPoolExecutor(max_workers=400)


def fetch(n):
    return urllib.request.urlopen(f"http://localhost:8221/shard/{n}", timeout=5).read()


def call(n):
    first = pool.submit(fetch, n)
    if not HEDGE:
        return first.result()
    done, _ = wait([first], timeout=HEDGE)
    if done:
        return first.result()
    done, _ = wait([first, pool.submit(fetch, n)], return_when=FIRST_COMPLETED)
    return done.pop().result()


def render():
    if FANOUT == "sequential":
        return [call(n) for n in range(SHARDS)]
    return list(pool.map(call, range(SHARDS)))


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        try:
            parts, code = render(), 200
            body = b"page with %d sections\n" % len(parts)
        except Exception as e:
            code, body = 502, f"{e}\n".encode()
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


ThreadingHTTPServer.daemon_threads = True
ThreadingHTTPServer.request_queue_size = 1024
ThreadingHTTPServer(("0.0.0.0", 8220), H).serve_forever()
