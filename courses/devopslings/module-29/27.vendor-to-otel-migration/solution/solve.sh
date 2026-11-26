#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# One pipeline, two exporters: Acme keeps everything it has today while Tempo
# fills up beside it. The plan cuts over only after a week-plus of measured
# parity, with alerts and dashboards already moved and Acme still receiving.
set -euo pipefail
. /usr/local/lib/obs.sh
python3 - <<'PY'
import yaml
p = "/obs/otel/collector.yaml"
c = yaml.safe_load(open(p))
c["exporters"]["otlphttp/tempo"] = {"endpoint": "http://tempo:4318"}
c["service"]["pipelines"]["traces"]["exporters"] = ["otlphttp/acme", "otlphttp/tempo"]
yaml.safe_dump(c, open(p, "w"), sort_keys=False)
PY
collector_settle
cat > /obs/answers/migration.txt <<'TXT'
phases: instrument, dual-ship, parity, move-dashboards, move-alerts, cut-over, decommission
parity_metric: spans per service per hour, and error rate and p99 latency per route, from Acme and from the new stack side by side
parity_threshold: 1% difference in span count, 5% in p99
parity_window: 14 days
alerts: rebuilt as Prometheus rules and run in parallel with Acme's for two weeks, both routed to a test channel and compared; the pager moves service by service once each fired when Acme's did
dashboards: rebuilt in Grafana from span metrics and Tempo, compared side by side with Acme's for the same hour, then Acme's are marked read-only
rollback: Acme keeps receiving everything until decommission, 30 days after cut-over; if the new stack misses an incident or parity drifts past threshold, the pager goes back to Acme's alerts the same day
TXT
