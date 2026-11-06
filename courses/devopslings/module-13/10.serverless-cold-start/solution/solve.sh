#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail
cd /root/quote

# Module scope runs once per instance, in the init phase, before the first
# request and off the function's timeout.
cat > src/handler.py <<'PY'
"""quote: prices an order from the pricing service's rate table."""
import json
import os
import urllib.request

RATES_URL = os.environ["RATES_URL"]


def fetch_rates():
    with urllib.request.urlopen(RATES_URL, timeout=10) as r:
        return json.load(r)


RATES = fetch_rates()


def handler(event, context):
    item = event["item"]
    qty = int(event.get("qty", 1))
    return {"item": item, "qty": qty, "total": round(RATES[item] * qty, 2)}
PY
tofu apply -auto-approve -input=false

ms() { curl -sS -o /dev/null -w '%{time_total}' -X POST -d '{"item": "widget"}' \
  http://floci:4566/2015-03-31/functions/quote/invocations | awk '{ printf "%d", $1 * 1000 }'; }
# The apply replaced the code, so no instance is running: this call is cold.
cold=$(ms)
warm=$( { ms; echo; ms; echo; ms; echo; } | sort -n | head -1)
printf 'cold_ms=%s\nwarm_ms=%s\n' "$cold" "$warm" > LATENCY
cat LATENCY
