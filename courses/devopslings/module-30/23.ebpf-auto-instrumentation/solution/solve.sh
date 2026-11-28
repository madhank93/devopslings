#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# ledger-legacy listens on :9480, so discovery on :8080 attaches to nothing;
# and the 5% ratio sampler, sized for the payments gateway's traffic, drops
# nineteen of every twenty spans. Select the right port and keep every trace.
set -euo pipefail
cat > /obs/beyla/beyla.yaml <<'YAML'
discovery:
  instrument:
    - open_ports: 9480
      name: ledger-legacy

otel_traces_export:
  endpoint: http://tempo:4318

prometheus_export:
  port: 9400
YAML
