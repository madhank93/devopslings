#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The Collector turns the delta stream into running totals before Prometheus
# sees it, so every SDK that sends deltas is covered, not just this one.
set -euo pipefail
python3 - <<'PY'
import yaml
p = "/obs/otel/collector.yaml"
c = yaml.safe_load(open(p))
c["processors"]["deltatocumulative"] = {}
c["service"]["pipelines"]["metrics"]["processors"] = ["deltatocumulative", "batch"]
open(p, "w").write(yaml.safe_dump(c, sort_keys=False))
PY
