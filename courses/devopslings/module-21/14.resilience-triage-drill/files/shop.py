"""shop — the drill's storefront, run inside the checkout container on :8214.

/checkout prices an item through pricing (via toxiproxy) with every pattern the
module built: a read timeout, a bulkhead, retries, a circuit breaker and a
fallback price. /browse never calls pricing; it asks the recommendations
service, and serves bestsellers when that fails.

Every knob comes from the environment, which gameday.sh fills from
sandboxes/chaos-stack/.env. /stats reports what shop itself saw, per phase of
the game day (the X-Phase header the load test sends).
"""

import os
import random
import threading
import time
import uuid

import requests
from flask import Flask, jsonify, request

PRICING_URL = "http://toxiproxy:21214"
RECS_URL = os.environ.get("RECS_URL", "")
THREADS = 16

TIMEOUT = float(os.environ.get("PRICING_TIMEOUT") or 0)          # 0 = wait forever
POOL = int(os.environ.get("PRICING_POOL") or 0)                   # 0 = no cap
FALLBACK = os.environ.get("FALLBACK_PRICE", "")                   # empty = answer 503
FALLBACK_VALUE = float(FALLBACK) if FALLBACK else None
ATTEMPTS = max(1, int(os.environ.get("RETRY_MAX_ATTEMPTS") or 1))
RETRY_ON = {s.strip() for s in os.environ.get("RETRY_ON", "").split(",") if s.strip()}
BACKOFF = 0.1                                                     # full jitter from 100ms
THRESHOLD = int(os.environ.get("BREAKER_THRESHOLD") or 0)         # 0 = no breaker
COOLDOWN = float(os.environ.get("BREAKER_COOLDOWN_S") or 5)

app = Flask(__name__)
lock = threading.Lock()
pool = threading.BoundedSemaphore(POOL) if POOL > 0 else None
PHASE_KEYS = ("checkouts", "from_pricing", "fallback", "not_found", "failed_503",
              "pricing_calls", "timeouts", "connect_errors", "pool_refused",
              "breaker_refused", "max_ms")
stats = {"phases": {}, "breaker_opens": 0, "browse": 0, "browse_max_ms": 0,
         "recs_failed": 0, "recs_error": ""}


def bump(phase, key, n=1):
    with lock:
        p = stats["phases"].setdefault(phase, dict.fromkeys(PHASE_KEYS, 0))
        if key == "max_ms":
            p[key] = max(p[key], n)
        else:
            p[key] += n


class Breaker:
    """Closed until THRESHOLD consecutive failures; open for COOLDOWN; then
    one trial call, which closes it on success and reopens it on failure."""

    def __init__(self):
        self.state, self.failures, self.opened_at, self.trial = "closed", 0, 0.0, False

    def allow(self):
        if THRESHOLD <= 0 or self.state == "closed":
            return True
        if self.state == "open":
            if time.monotonic() - self.opened_at < COOLDOWN:
                return False
            self.state, self.trial = "half-open", False
        if self.trial:
            return False
        self.trial = True
        return True

    def success(self):
        self.state, self.failures, self.trial = "closed", 0, False

    def failure(self):
        if THRESHOLD <= 0:
            return
        self.failures += 1
        self.trial = False
        if self.state == "half-open" or (self.state == "closed" and self.failures >= THRESHOLD):
            if self.state != "open":
                stats["breaker_opens"] += 1
            self.state, self.opened_at = "open", time.monotonic()


cb = Breaker()


@app.get("/health")
def health():
    return jsonify(status="ok")


@app.get("/stats")
def get_stats():
    with lock:
        return jsonify(stats)


@app.get("/browse")
def browse():
    started = time.monotonic()
    source = "bestsellers"
    if RECS_URL:
        try:
            requests.get(f"{RECS_URL}/recs", timeout=(0.5, 0.5)).raise_for_status()
            source = "recs"
        except Exception as exc:
            with lock:
                stats["recs_failed"] += 1
                stats["recs_error"] = type(exc).__name__
    ms = int((time.monotonic() - started) * 1000)
    with lock:
        stats["browse"] += 1
        stats["browse_max_ms"] = max(stats["browse_max_ms"], ms)
    return jsonify(status="ok", items=["kettle", "toaster", "lamp"], source=source)


def fallback(phase, reason):
    if FALLBACK_VALUE is None:
        bump(phase, "failed_503")
        return jsonify(status="error", error=reason), 503
    bump(phase, "fallback")
    return jsonify(status="ok", price=FALLBACK_VALUE, source="fallback", reason=reason)


def price(phase, sku):
    rid, kind = uuid.uuid4().hex, "connect"
    for attempt in range(1, ATTEMPTS + 1):
        bump(phase, "pricing_calls")
        try:
            r = requests.get(f"{PRICING_URL}/price", params={"sku": sku},
                             headers={"X-Request-Id": rid},
                             timeout=(0.5, TIMEOUT if TIMEOUT > 0 else None))
            if r.status_code == 200:
                with lock:
                    cb.success()
                bump(phase, "from_pricing")
                return jsonify(status="ok", price=r.json()["price"], source="pricing")
            kind = f"{r.status_code // 100}xx"
        except requests.Timeout:
            kind = "timeout"
            bump(phase, "timeouts")
        except requests.ConnectionError as exc:
            # requests reports a read timeout that fires mid-body as a
            # connection error; it is still a timeout.
            if "timed out" in str(exc):
                kind = "timeout"
                bump(phase, "timeouts")
            else:
                kind = "connect"
                bump(phase, "connect_errors")
        if kind not in RETRY_ON or attempt == ATTEMPTS:
            break
        time.sleep(random.uniform(0, BACKOFF * 2 ** (attempt - 1)))
    if kind == "4xx":
        # An answer about the request, not a failure of pricing.
        with lock:
            cb.success()
        bump(phase, "not_found")
        return jsonify(status="error", error="unknown sku"), 404
    with lock:
        cb.failure()
    return fallback(phase, kind)


@app.get("/checkout")
def checkout():
    phase = request.headers.get("X-Phase", "manual")
    started = time.monotonic()
    bump(phase, "checkouts")
    if pool is not None and not pool.acquire(blocking=False):
        bump(phase, "pool_refused")
        resp = fallback(phase, "pricing pool full")
    else:
        try:
            with lock:
                allowed = cb.allow()
            if allowed:
                resp = price(phase, request.args.get("sku", "widget"))
            else:
                bump(phase, "breaker_refused")
                resp = fallback(phase, "breaker open")
        finally:
            if pool is not None:
                pool.release()
    bump(phase, "max_ms", int((time.monotonic() - started) * 1000))
    return resp


def recs_log():
    last = 0
    while True:
        time.sleep(5)
        with lock:
            n, err = stats["recs_failed"], stats["recs_error"]
        if n > last:
            print(f"recs: {n - last} calls failed in the last 5s ({err}); serving bestsellers",
                  flush=True)
        last = n


if __name__ == "__main__":
    from waitress import serve

    print(f"shop up: {THREADS} worker threads, timeout={TIMEOUT or 'none'} "
          f"pool={POOL or 'unbounded'} attempts={ATTEMPTS} retry_on={','.join(sorted(RETRY_ON)) or '-'} "
          f"breaker={THRESHOLD or 'off'}/{COOLDOWN}s fallback={FALLBACK or 'none'}", flush=True)
    threading.Thread(target=recs_log, daemon=True).start()
    serve(app, host="0.0.0.0", port=8214, threads=THREADS, connection_limit=2000)
