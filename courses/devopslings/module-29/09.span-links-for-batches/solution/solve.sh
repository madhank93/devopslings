#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# A span has one parent but any number of links. The batch span starts a trace
# of its own and links to the producer context of every message in the batch,
# so each order's trace is reachable from the work that processed it.
set -euo pipefail
python3 - <<'PY'
p = "/obs/apps/fulfil.py"
s = open(p).read()
s = s.replace('''    # A span has one parent; the first order's will do.
    parent = propagate.extract(batch[0]["headers"])
    with tracer.start_as_current_span("orders process", context=parent,
                                      kind=trace.SpanKind.CONSUMER) as span:''',
'''    links = [trace.Link(trace.get_current_span(propagate.extract(m["headers"])).get_span_context())
             for m in batch]
    with tracer.start_as_current_span("orders process", links=links,
                                      kind=trace.SpanKind.CONSUMER) as span:''')
open(p, "w").write(s)
PY
grep -q 'links=links' /obs/apps/fulfil.py
