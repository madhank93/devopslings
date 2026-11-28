#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# propagate.inject writes every configured propagator's header, so baggage goes
# wherever traceparent goes. The call that leaves the company injects from a
# context with the baggage cleared: the provider still gets a traceparent to
# correlate on, and ledger, called with the full context, still gets the tenant.
set -euo pipefail
python3 - <<'PY'
p = "/obs/apps/checkout.py"
s = open(p).read()
s = s.replace('''def call(url, payload):
    headers = {"Content-Type": "application/json"}
    propagate.inject(headers)''', '''def call(url, payload, ctx=None):
    headers = {"Content-Type": "application/json"}
    propagate.inject(headers, context=ctx)''')
s = s.replace('call(PROVIDER, {"reference": order["order_id"], "amount": order["amount"]})',
              'call(PROVIDER, {"reference": order["order_id"], "amount": order["amount"]}, baggage.clear())')
open(p, "w").write(s)
PY
grep -q 'baggage.clear())' /obs/apps/checkout.py
