#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# servicegraph pairs a CLIENT span with the SERVER span that is its child in
# another service. Every outgoing call becomes CLIENT and every handler SERVER.
set -euo pipefail
python3 - <<'PY'
import re
for app in ("checkout", "fulfil", "ledger"):
    p = f"/obs/apps/{app}.py"
    s = open(p).read()
    s = re.sub(r'start_as_current_span\("(POST /[a-z]+)"\) as span:',
               r'start_as_current_span("\1", kind=trace.SpanKind.CLIENT) as span:', s)
    s = s.replace("context=ctx):", "context=ctx, kind=trace.SpanKind.SERVER):")
    open(p, "w").write(s)
PY
grep -c 'SpanKind.CLIENT' /obs/apps/checkout.py /obs/apps/fulfil.py
grep -q 'SpanKind.SERVER' /obs/apps/ledger.py
