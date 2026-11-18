"""search — four replicas of the search API, as Prometheus sees them, on
:9401-:9404 (replicas a-d).

Each replica exports the same latency twice: search_latency_seconds, a summary
whose quantiles the replica computes over its own last minute, and
search_latency_hist_seconds, a histogram. Replicas a, b and c each take 50
requests a second and answer in about 80ms. Replica d holds the hot shard: it
takes 150 a second and answers in about 300ms."""
import bisect
import collections
import math
import random
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BUCKETS = (0.025, 0.05, 0.1, 0.25, 0.5, 0.75, 1, 1.5, 2, 3, 5)
REPLICAS = {"a": (9401, 50, 0.08, 0.5), "b": (9402, 50, 0.08, 0.5),
            "c": (9403, 50, 0.08, 0.5), "d": (9404, 150, 0.30, 0.6)}


class Replica:
    def __init__(self, rate, median, sigma):
        self.rate, self.median, self.sigma = rate, median, sigma
        self.lock = threading.Lock()
        self.window = collections.deque()
        self.counts = [0] * (len(BUCKETS) + 1)
        self.total = 0.0
        self.n = 0

    def run(self):
        rnd = random.Random()
        while True:
            now = time.monotonic()
            with self.lock:
                for _ in range(self.rate // 10):
                    v = rnd.lognormvariate(math.log(self.median), self.sigma)
                    self.window.append((now, v))
                    self.counts[bisect.bisect_left(BUCKETS, v)] += 1
                    self.total += v
                    self.n += 1
                while self.window and self.window[0][0] < now - 60:
                    self.window.popleft()
            time.sleep(0.1)

    def exposition(self):
        with self.lock:
            vals = sorted(v for _, v in self.window)
            counts, total, n = list(self.counts), self.total, self.n
        out = ["# HELP search_latency_seconds Search latency; quantiles over this replica's last minute.",
               "# TYPE search_latency_seconds summary"]
        for q in (0.5, 0.9, 0.99):
            v = vals[min(len(vals) - 1, int(q * len(vals)))] if vals else float("nan")
            out.append(f'search_latency_seconds{{quantile="{q}"}} {v}')
        out += [f"search_latency_seconds_sum {total}", f"search_latency_seconds_count {n}",
                "# HELP search_latency_hist_seconds Search latency.",
                "# TYPE search_latency_hist_seconds histogram"]
        cum = 0
        for b, c in zip(BUCKETS + ("+Inf",), counts):
            cum += c
            out.append(f'search_latency_hist_seconds_bucket{{le="{b}"}} {cum}')
        out += [f"search_latency_hist_seconds_sum {total}", f"search_latency_hist_seconds_count {n}"]
        return ("\n".join(out) + "\n").encode()


def serve(port, replica):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_GET(self):
            body = replica.exposition()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    ThreadingHTTPServer(("0.0.0.0", port), H).serve_forever()


for port, rate, median, sigma in REPLICAS.values():
    r = Replica(rate, median, sigma)
    threading.Thread(target=r.run, daemon=True).start()
    threading.Thread(target=serve, args=(port, r), daemon=True).start()
threading.Event().wait()
