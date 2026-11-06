#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Two relabel fixes in the shop job, none in the pipeline's targets file:
#   keep env=prod      — the filter matched "production", a value no target has,
#                        so it dropped shop along with the retired host
#   __address__ → :9101 — discovery publishes the service port; metrics are on 9101
set -euo pipefail
python3 - <<'PY'
p = "/obs/prometheus/prometheus.yml"
s = open(p).read()
old = """      - source_labels: [env]
        regex: production
        action: keep
"""
new = """      - source_labels: [env]
        regex: prod
        action: keep
      # Discovery publishes the service port; shop serves metrics on 9101.
      - source_labels: [__address__]
        regex: '([^:]+):\\d+'
        replacement: '${1}:9101'
        target_label: __address__
"""
assert old in s
open(p, "w").write(s.replace(old, new))
PY
obs-reload
