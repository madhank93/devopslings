"""Last night's load test against search: 1,000 requests, one duration each.

  durations.py dump   print them one per line, in the order they were sent
  durations.py        serve each as a series on :9400,
                      search_test_request_duration_ms{request="0001"}
"""
import random
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

rnd = random.Random(20)
seen = set()
values = []
while len(values) < 1000:
    # Mostly a lognormal body around 120ms, with a slow tail of requests that
    # waited on a cold index shard. Distinct values keep every rank unambiguous.
    v = rnd.uniform(700, 2400) if rnd.random() < 1 / 30 else rnd.lognormvariate(4.8, 0.35)
    v = round(v, 1)
    if v not in seen:
        seen.add(v)
        values.append(v)

if sys.argv[1:] == ["dump"]:
    print("\n".join(map(str, values)))
    sys.exit(0)

body = ("# HELP search_test_request_duration_ms How long one load-test request took.\n"
        "# TYPE search_test_request_duration_ms gauge\n" +
        "".join(f'search_test_request_duration_ms{{request="{i + 1:04d}"}} {v}\n'
                for i, v in enumerate(values))).encode()


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


ThreadingHTTPServer(("0.0.0.0", 9400), H).serve_forever()
