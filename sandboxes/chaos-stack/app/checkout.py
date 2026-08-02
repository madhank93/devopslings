"""checkout — the service under test.

It calls the `pricing` service for every request. The only interesting thing
about it is how it makes that call, which is the subject of the lesson: the
client is configured entirely from the environment so a student can change its
behaviour without editing Python.

All traffic to pricing goes through toxiproxy, so a fault can be injected
between the two services without touching either one.
"""

import os
import time

import requests
from flask import Flask, jsonify

app = Flask(__name__)

PRICING_URL = os.environ.get("PRICING_URL", "http://toxiproxy:26379")

# The knobs the lesson is about. Defaults are the naive choices: wait forever,
# never retry, no fallback.
CONNECT_TIMEOUT = float(os.environ.get("PRICING_CONNECT_TIMEOUT", "0") or 0)
READ_TIMEOUT = float(os.environ.get("PRICING_READ_TIMEOUT", "0") or 0)
FALLBACK_PRICE = os.environ.get("PRICING_FALLBACK", "")


def _timeout():
    """requests takes None to mean 'block indefinitely'."""
    if CONNECT_TIMEOUT <= 0 and READ_TIMEOUT <= 0:
        return None
    return (CONNECT_TIMEOUT or 3.0, READ_TIMEOUT or 3.0)


@app.get("/health")
def health():
    return jsonify(status="ok")


@app.get("/checkout")
def checkout():
    started = time.monotonic()
    try:
        r = requests.get(f"{PRICING_URL}/price", timeout=_timeout())
        r.raise_for_status()
        price = r.json()["price"]
        source = "pricing"
    except Exception as exc:
        if not FALLBACK_PRICE:
            # No fallback configured: the failure propagates to the caller.
            return (
                jsonify(
                    status="error",
                    error=type(exc).__name__,
                    elapsed_ms=int((time.monotonic() - started) * 1000),
                ),
                503,
            )
        price = float(FALLBACK_PRICE)
        source = "fallback"

    return jsonify(
        status="ok",
        price=price,
        source=source,
        elapsed_ms=int((time.monotonic() - started) * 1000),
    )


if __name__ == "__main__":
    from waitress import serve

    print(f"checkout up, pricing={PRICING_URL}, timeout={_timeout()}", flush=True)
    serve(app, host="0.0.0.0", port=8080, threads=16)
