#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# A TracerProvider named for the service, a batch processor feeding the OTLP
# exporter, and one span around the work that carries the request's values.
set -euo pipefail
python3 - <<'PY'
p = "/obs/apps/ledger.py"
s = open(p).read()
s = s.replace("ENTRIES = []\n", '''from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

provider = TracerProvider(resource=Resource.create({"service.name": "ledger"}))
provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(endpoint="http://tempo:4318/v1/traces")))
trace.set_tracer_provider(provider)
tracer = trace.get_tracer("ledger")

ENTRIES = []
''')
s = s.replace('''    """Write one entry to the books."""
    time.sleep(0.01)
    ENTRIES.append(entry)''', '''    """Write one entry to the books."""
    with tracer.start_as_current_span("record entry") as span:
        span.set_attribute("order.id", entry["order_id"])
        span.set_attribute("entry.amount", float(entry["amount"]))
        span.set_attribute("entry.currency", entry["currency"])
        time.sleep(0.01)
        ENTRIES.append(entry)''')
open(p, "w").write(s)
PY
grep -q 'start_as_current_span("record entry")' /obs/apps/ledger.py
