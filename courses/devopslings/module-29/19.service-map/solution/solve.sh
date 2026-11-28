#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The servicegraph connector pairs each CLIENT span with the SERVER span it
# caused and emits one request counter and latency histogram per edge. Each
# edge's server latency includes everything the server waited on, so the slow
# call is the one whose server is slow while that server's own calls are fast:
# checkout -> billing, since billing -> ledger answers in milliseconds.
set -euo pipefail
. /usr/local/lib/obs.sh
python3 - <<'PY'
import yaml
p = "/obs/otel/collector.yaml"
c = yaml.safe_load(open(p))
c["connectors"] = {"servicegraph": {"metrics_flush_interval": "5s"}}
c["exporters"]["prometheus"] = {"endpoint": "0.0.0.0:8889"}
pl = c["service"]["pipelines"]
pl["traces"]["exporters"].append("servicegraph")
pl["metrics/servicegraph"] = {"receivers": ["servicegraph"], "exporters": ["prometheus"]}
yaml.safe_dump(c, open(p, "w"), sort_keys=False)
PY
cat >> /obs/prometheus/prometheus.yml <<'YML'

  - job_name: servicegraph
    static_configs:
      - targets: ["collector:8889"]
YML
obs_reload
collector_settle
cat > /obs/answers/bottleneck.txt <<'TXT'
edge: checkout -> billing
metric: histogram_quantile(0.95, sum by (client, server, le) (rate(traces_service_graph_request_server_seconds_bucket[1m])))
TXT
