"""checkout with a circuit breaker: the circuit-breaker lesson's harness.

Makes the same pricing call as app/checkout.py, but every call is gated by the
student's Breaker (breaker.py beside this file). Serves :8081 inside the
checkout container, next to the real checkout on :8080.

/stats reports what the grader cannot see from responses alone: the most calls
in flight at once after the breaker first refused one — a half-open breaker
admits exactly one.
"""

import threading
import time

import requests
from flask import Flask, jsonify

import breaker

PRICING_URL = "http://toxiproxy:21080"
FALLBACK_PRICE = 39.99

app = Flask(__name__)
cb = breaker.Breaker()
lock = threading.Lock()
stats = {"calls": 0, "refused": 0,
         "later_inflight": 0, "max_later_inflight": 0}


@app.get("/health")
def health():
    return jsonify(status="ok")


@app.get("/stats")
def get_stats():
    with lock:
        return jsonify(stats)


@app.get("/checkout")
def checkout():
    started = time.monotonic()
    later = False
    with lock:
        allowed = bool(cb.allow())
        if not allowed:
            stats["refused"] += 1
        else:
            stats["calls"] += 1
            if stats["refused"]:
                later = True
                stats["later_inflight"] += 1
                stats["max_later_inflight"] = max(stats["max_later_inflight"],
                                                  stats["later_inflight"])

    price, source = FALLBACK_PRICE, "fallback"
    if allowed:
        ok = False
        try:
            r = requests.get(f"{PRICING_URL}/price", timeout=breaker.TIMEOUT)
            r.raise_for_status()
            price, source, ok = r.json()["price"], "pricing", True
        except Exception:
            pass
        with lock:
            if later:
                stats["later_inflight"] -= 1
            cb.success() if ok else cb.failure()

    return jsonify(status="ok", price=price, source=source, called_pricing=allowed,
                   elapsed_ms=int((time.monotonic() - started) * 1000))


if __name__ == "__main__":
    from waitress import serve

    serve(app, host="0.0.0.0", port=8081, threads=16)
