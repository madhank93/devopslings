#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The formatter runs in the thread that logs, inside the request's span, so it
# reads the trace id from the current span. Grafana's Loki datasource gets a
# derived field that captures that id from the line and opens it in Tempo.
set -euo pipefail
python3 - <<'PY'
p = "/obs/apps/lab.py"
s = open(p).read()
old = '        rec.update(getattr(record, "fields", {}))\n'
assert old in s
s = s.replace(old, old +
    '        ctx = trace.get_current_span().get_span_context()\n'
    '        if ctx.is_valid:\n'
    '            rec["trace_id"] = format(ctx.trace_id, "032x")\n')
open(p, "w").write(s)

p = "/obs/grafana/provisioning/datasources/logs-traces.yml"
s = open(p).read()
old = "    url: http://loki:3100\n"
assert old in s
s = s.replace(old, old +
    "    jsonData:\n"
    "      derivedFields:\n"
    "        - name: TraceID\n"
    "          matcherRegex: '\"trace_id\": \"([0-9a-f]{32})\"'\n"
    "          url: '$${__value.raw}'\n"
    "          datasourceUid: tempo\n", 1)
open(p, "w").write(s)
PY
curl -sf -u admin:admin -X POST http://grafana:3000/api/admin/provisioning/datasources/reload >/dev/null
