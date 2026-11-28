#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# With PyroscopeSpanProcessor on the provider, each price-quote span carries
# pyroscope.profile.id and its profile shows ~all samples in mortality_table,
# called from rider_premium: the table is rebuilt for every rider of every
# quote. It depends on nothing per-quote, so build it once.
set -euo pipefail
mkdir -p /obs/answers
echo "function=mortality_table" > /obs/answers/span.txt
python3 - <<'PY'
p = "/obs/quoter/quoter.py"
s = open(p).read()
s = s.replace("from opentelemetry.sdk.trace.export import BatchSpanProcessor\n",
              "from opentelemetry.sdk.trace.export import BatchSpanProcessor\nfrom pyroscope.otel import PyroscopeSpanProcessor\n")
s = s.replace("provider.add_span_processor(BatchSpanProcessor(",
              "provider.add_span_processor(PyroscopeSpanProcessor())\nprovider.add_span_processor(BatchSpanProcessor(")
s = s.replace("def base_premium(", "MORTALITY = mortality_table()\n\n\ndef base_premium(")
s = s.replace("(1 - mortality_table()[age])", "(1 - MORTALITY[age])")
open(p, "w").write(s)
PY
