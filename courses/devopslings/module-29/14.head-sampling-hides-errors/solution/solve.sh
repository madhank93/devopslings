#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# A head sampler decides before the request has run, so it cannot know which
# traces will fail or be slow. checkout now sends every trace, and the
# Collector decides once each trace is complete: keep errors, keep anything
# over 500ms, and keep 1% of the rest.
set -euo pipefail
. /usr/local/lib/obs.sh
sed -i 's/sampler=ParentBased(TraceIdRatioBased(0.01)))/sampler=ParentBased(TraceIdRatioBased(1.0)))/' /obs/apps/checkout.py
grep -q 'TraceIdRatioBased(1.0)' /obs/apps/checkout.py
python3 - <<'PY'
import yaml
p = "/obs/otel/collector.yaml"
c = yaml.safe_load(open(p))
c["processors"]["tail_sampling"] = {
    "decision_wait": "5s",
    "policies": [
        {"name": "errors", "type": "status_code", "status_code": {"status_codes": ["ERROR"]}},
        {"name": "slow", "type": "latency", "latency": {"threshold_ms": 500}},
        {"name": "baseline", "type": "probabilistic", "probabilistic": {"sampling_percentage": 1}},
    ],
}
c["service"]["pipelines"]["traces"]["processors"] = ["tail_sampling", "batch"]
yaml.safe_dump(c, open(p, "w"), sort_keys=False)
PY
collector_settle
