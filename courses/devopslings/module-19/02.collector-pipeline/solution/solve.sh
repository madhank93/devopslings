#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Receive OTLP over HTTP as well as gRPC; run memory_limiter first, normalise
# url.path to http.route before the filter that matches on it, stamp the
# environment, batch last; export to Loki.
set -euo pipefail
python3 - <<'PY'
import yaml
p = "/obs/otel/collector.yaml"
c = yaml.safe_load(open(p))
c["receivers"]["otlp"]["protocols"]["http"] = {"endpoint": "0.0.0.0:4318"}
c["service"]["pipelines"]["logs"]["processors"] = [
    "memory_limiter", "resource/env", "attributes/normalize", "filter/healthchecks", "batch"]
c["service"]["pipelines"]["logs"]["exporters"] = ["otlphttp/loki"]
yaml.safe_dump(c, open(p, "w"), sort_keys=False)
PY
