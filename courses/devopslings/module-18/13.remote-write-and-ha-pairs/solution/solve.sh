#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# One cluster label shared by the pair, a __replica__ label per member. Mimir
# accepts one member's samples per cluster and drops __replica__ on the way in.
set -euo pipefail
sed -i 's/^    replica: a$/    cluster: shop-prod\n    __replica__: a/' /obs/prometheus-2/prometheus.yml
sed -i 's/^    replica: b$/    cluster: shop-prod\n    __replica__: b/' /obs/prometheus-3/prometheus.yml
curl -sf -X POST prometheus-2:9090/-/reload
curl -sf -X POST prometheus-3:9090/-/reload
