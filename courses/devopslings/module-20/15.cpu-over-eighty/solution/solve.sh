#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The CPU alert goes; in its place, the share of shop's requests that fail.
# Every cause of harm, db or shop's own bug, ends up there, and a busy CPU
# that serves every request does not. Runs in the box container.
set -euo pipefail
. /usr/local/lib/obs.sh
cat > /obs/prometheus/rules/capacity.yml <<'YML'
groups:
  - name: shop-customers
    rules:
      - alert: ShopRequestsFailing
        expr: |
          sum(rate(shop_http_requests_total{code=~"5.."}[1m]))
            / sum(rate(shop_http_requests_total[1m])) > 0.05
        for: 30s
        labels:
          severity: page
        annotations:
          summary: more than 5% of shop requests are failing
YML
obs_reload
