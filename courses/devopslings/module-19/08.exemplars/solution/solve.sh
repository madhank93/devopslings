#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Attach the order's trace id to each observation while its span is still at
# hand, and let Prometheus negotiate OpenMetrics, the only format that carries
# exemplars.
set -euo pipefail
. /usr/local/lib/obs.sh
python3 - <<'PY'
p = "/obs/apps/checkout.py"
s = open(p).read()
s = s.replace("        publish(order)\n    DURATION.observe(time.perf_counter() - start)\n",
              "        publish(order)\n"
              "        trace_id = format(span.get_span_context().trace_id, \"032x\")\n"
              "    DURATION.observe(time.perf_counter() - start, exemplar={\"trace_id\": trace_id})\n")
open(p, "w").write(s)

p = "/obs/prometheus/prometheus.yml"
s = open(p).read()
s = s.replace("    scrape_protocols: [PrometheusText0.0.4]\n", "")
open(p, "w").write(s)
PY
grep -q 'exemplar=' /obs/apps/checkout.py
obs_reload >/dev/null
cat > /obs/answers/exemplars.txt <<'TXT'
cause: about 3% of orders apply a coupon whose first lookup times out after 1s and is retried
TXT
