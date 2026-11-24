#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# memory_limiter first in every pipeline, sized from the container's own
# limit, so the Collector refuses data before the kernel kills it; batch last.
set -euo pipefail
. /usr/local/lib/obs.sh
python3 - <<'PY'
import yaml
p = "/obs/otel/collector.yaml"
c = yaml.safe_load(open(p))
c["processors"]["memory_limiter"] = {
    "check_interval": "100ms",
    "limit_percentage": 70,
    "spike_limit_percentage": 25,
}
for pl in c["service"]["pipelines"].values():
    rest = [x for x in pl.get("processors", []) if x not in ("memory_limiter", "batch")]
    pl["processors"] = ["memory_limiter", *rest, "batch"]
yaml.safe_dump(c, open(p, "w"), sort_keys=False)
PY
collector_settle
