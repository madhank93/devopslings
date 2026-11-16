#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Label by service and level: 6 x 3 combinations, so at most 18 streams. The
# lookup selects the one stream a failed payments request can be in and finds
# the request id in its lines.
set -euo pipefail
cat > /obs/vector/ship.yaml <<'YML'
transforms:
  parse:
    type: remap
    inputs: [shop]
    source: |
      . = merge!(., parse_json!(.message))

sinks:
  loki:
    type: loki
    inputs: [parse]
    endpoint: http://loki:3100
    encoding:
      codec: text
    labels:
      app: shop
      service: "{{ service }}"
      level: "{{ level }}"
YML
printf '%s\n' '{app="shop", service="payments", level="error"} |= "${request_id}"' > /obs/queries/lookup.logql
