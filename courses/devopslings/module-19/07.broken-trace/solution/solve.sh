#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# broker queues a message's body and nothing else, so the trace context has to
# travel inside it: checkout injects it into the message while its publish span
# is current, and fulfil extracts it and starts its consumer span as a child.
set -euo pipefail
python3 - <<'PY'
p = "/obs/apps/checkout.py"
s = open(p).read()
s = s.replace("from opentelemetry import trace\n", "from opentelemetry import propagate, trace\n")
s = s.replace(
    '        req = urllib.request.Request("http://broker:8080/publish", data=json.dumps(order).encode(),',
    '        carrier = {}\n'
    '        propagate.inject(carrier)\n'
    '        message = dict(order, trace_context=carrier)\n'
    '        req = urllib.request.Request("http://broker:8080/publish", data=json.dumps(message).encode(),')
open(p, "w").write(s)

p = "/obs/apps/fulfil.py"
s = open(p).read()
s = s.replace(
    '    with tracer.start_as_current_span("process orders", kind=trace.SpanKind.CONSUMER) as span:',
    '    ctx = propagate.extract(order.pop("trace_context", {}))\n'
    '    with tracer.start_as_current_span("process orders", context=ctx, kind=trace.SpanKind.CONSUMER) as span:')
open(p, "w").write(s)
PY
grep -q trace_context /obs/apps/checkout.py
grep -q 'context=ctx' /obs/apps/fulfil.py
