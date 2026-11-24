"""nightly — the batch job, on a compressed schedule: one run every
NIGHTLY_EVERY seconds (default 20) stands in for one night. A run itself
takes up to 6 seconds, so pushes land 20 to 26 seconds apart.

A run that succeeds pushes its results to the Pushgateway under job="nightly"
and exits; the gauges stay there until the next push replaces them. While
/obs/run/nightly.fault exists, every run fails before it pushes anything.
"""
import os
import random
import time
import traceback

from prometheus_client import CollectorRegistry, Gauge, push_to_gateway

EVERY = int(os.environ.get("NIGHTLY_EVERY", "20"))


def run():
    time.sleep(random.uniform(0, 6))  # the work; a run takes a few seconds
    if os.path.exists("/obs/run/nightly.fault"):
        raise ConnectionError("warehouse export: connection refused")
    reg = CollectorRegistry()
    Gauge("nightly_last_success_timestamp_seconds", "When the last run finished, as a Unix time.",
          registry=reg).set_to_current_time()
    Gauge("nightly_records_processed", "Records the last run processed.", registry=reg).set(1200)
    push_to_gateway("pushgateway:9091", job="nightly", registry=reg)


while True:
    try:
        run()
        print("run ok", flush=True)
    except Exception:
        traceback.print_exc()
    time.sleep(EVERY)
