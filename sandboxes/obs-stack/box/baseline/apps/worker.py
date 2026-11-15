"""worker — drains a job queue in bursts. Metrics on :9101.

It works for 20 seconds, then waits 10 for the next batch. Every finished job
is also appended to /obs/run/ledger-<id>.log, the billing system's own record,
which survives a restart of the worker.
"""
import os
import random
import time

from prometheus_client import Counter, Gauge, start_http_server

WORKER = os.environ.get("WORKER_ID", "a")
PROCESSED = Counter("worker_jobs_processed_total", "Jobs finished since the worker started.")
QUEUE = Gauge("worker_queue_depth", "Jobs waiting in the queue.")

start_http_server(9101)
ledger = open(f"/obs/run/ledger-{WORKER}.log", "a", buffering=1)
offset = 0 if WORKER == "a" else 7
while True:
    busy = (time.time() + offset) % 30 < 20
    QUEUE.set(random.randint(40, 60) if busy else random.randint(0, 5))
    if busy:
        PROCESSED.inc()
        ledger.write(f"{time.time():.3f}\n")
    time.sleep(0.2)
