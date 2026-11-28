#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Each gateway gets two pipelines. The first takes spans from the services and
# routes them by trace ID to one of the two gateways' second pipeline, which
# tail-samples whole traces and exports to Tempo.
set -euo pipefail
python3 - <<'PY'
import yaml
for f in ("collector", "collector-2"):
    p = f"/obs/otel/{f}.yaml"
    c = yaml.safe_load(open(p))
    c["receivers"]["otlp/sampling"] = {"protocols": {"grpc": {"endpoint": "0.0.0.0:4417"}}}
    c["exporters"]["loadbalancing"] = {
        "routing_key": "traceID",
        "protocol": {"otlp": {"tls": {"insecure": True}}},
        "resolver": {"static": {"hostnames": ["collector:4417", "collector-2:4417"]}},
    }
    c["service"]["pipelines"] = {
        "traces/route": {"receivers": ["otlp"], "processors": [], "exporters": ["loadbalancing"]},
        "traces": {"receivers": ["otlp/sampling"], "processors": ["tail_sampling", "batch"],
                   "exporters": ["otlphttp/tempo"]},
    }
    yaml.safe_dump(c, open(p, "w"), sort_keys=False)
PY
sleep 2
