"""shop — two routes, one worker pool.

/browse is served from memory. /checkout calls pricing through toxiproxy. Both
are handled by the same waitress thread pool, which is the point: nothing
stops one route from holding every thread.

PRICING_POOL is a bulkhead — a cap on how many threads may be inside a pricing
call at once. A request that finds it full is refused immediately instead of
queueing for a thread. 0 means no cap.
"""

import os
import threading
import time

import requests
from flask import Flask, jsonify

app = Flask(__name__)

PRICING_URL = os.environ.get("PRICING_URL", "http://toxiproxy:21080")
# Each worker thread costs memory, and this container's budget allows 64.
MAX_THREADS = 64
THREADS = min(int(os.environ.get("SHOP_THREADS", "16") or 16), MAX_THREADS)
TIMEOUT = float(os.environ.get("PRICING_TIMEOUT", "0") or 0)
POOL = int(os.environ.get("PRICING_POOL", "0") or 0)

pricing_slots = threading.BoundedSemaphore(POOL) if POOL > 0 else None


@app.get("/health")
def health():
    return jsonify(status="ok")


@app.get("/browse")
def browse():
    return jsonify(status="ok", items=["kettle", "toaster", "lamp"])


@app.get("/checkout")
def checkout():
    started = time.monotonic()
    if pricing_slots is not None and not pricing_slots.acquire(blocking=False):
        return jsonify(status="error", error="pricing pool full"), 503
    try:
        r = requests.get(f"{PRICING_URL}/price", timeout=TIMEOUT or None)
        r.raise_for_status()
        return jsonify(
            status="ok",
            price=r.json()["price"],
            elapsed_ms=int((time.monotonic() - started) * 1000),
        )
    except Exception as exc:
        return jsonify(status="error", error=type(exc).__name__), 503
    finally:
        if pricing_slots is not None:
            pricing_slots.release()


if __name__ == "__main__":
    from waitress import serve

    print(f"shop up: threads={THREADS} (max {MAX_THREADS}) "
          f"pricing_pool={POOL or 'unbounded'} timeout={TIMEOUT or 'none'}", flush=True)
    # The thread pool is the one shared resource under study, so the connection
    # ceiling is set well above anything the load test opens.
    serve(app, host="0.0.0.0", port=8080, threads=THREADS, connection_limit=2000)
