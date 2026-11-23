#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# spanmetrics has to see every span, so it gets a traces pipeline of its own
# with no sampler in it; the sampled pipeline still feeds Tempo. Its metrics
# leave through a prometheus exporter that Prometheus scrapes.
set -euo pipefail
. /usr/local/lib/obs.sh
python3 - <<'PY'
import yaml
p = "/obs/otel/collector.yaml"
c = yaml.safe_load(open(p))
c["connectors"] = {"spanmetrics": {"metrics_flush_interval": "5s"}}
c["exporters"]["prometheus"] = {"endpoint": "0.0.0.0:8889"}
pl = c["service"]["pipelines"]
pl["traces/red"] = {"receivers": ["otlp"], "processors": ["batch"], "exporters": ["spanmetrics"]}
pl["metrics/red"] = {"receivers": ["spanmetrics"], "exporters": ["prometheus"]}
yaml.safe_dump(c, open(p, "w"), sort_keys=False)
PY
cat >> /obs/prometheus/prometheus.yml <<'YML'

  - job_name: spanmetrics
    static_configs:
      - targets: ["collector:8889"]
YML
obs_reload
collector_settle
