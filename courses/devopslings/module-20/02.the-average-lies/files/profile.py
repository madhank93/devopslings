"""profile — the account-profile API's latency, as Prometheus sees it, on :9400.

Simulates 400 requests a second. Each user's profile lives on one of 50
session-store shards; three of those shards sit on a node that is swapping,
so every request for their users takes 1.2 to 2.8 seconds. The rest take
about 110ms."""
import math
import random
import threading
import time

from prometheus_client import Histogram, start_http_server

RATE, SHARDS, SLOW = 400, 50, {12, 29, 41}
latency = Histogram("profile_request_duration_seconds", "Time to serve one profile request.",
                    buckets=(0.05, 0.1, 0.2, 0.5, 1, 2, 5))


def traffic():
    rnd = random.Random()
    while True:
        for _ in range(RATE // 10):
            if rnd.randrange(SHARDS) in SLOW:
                latency.observe(rnd.uniform(1.2, 2.8))
            else:
                latency.observe(rnd.lognormvariate(math.log(0.11), 0.4))
        time.sleep(0.1)


start_http_server(9400)
threading.Thread(target=traffic, daemon=True).start()
threading.Event().wait()
