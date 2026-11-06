#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Prometheus evaluates the panel's expression every 5s and stores the result
# as one series per route; the panel reads that instead of 5 minutes of raw
# buckets at every step.
set -euo pipefail
cat > /obs/prometheus/rules/shop-latency.yml <<'YML'
groups:
  - name: shop-latency
    rules:
      - record: route:shop_http_request_duration_seconds:p99_rate5m
        expr: histogram_quantile(0.99, sum by (le, route) (rate(shop_http_request_duration_seconds_bucket[5m])))
YML
echo 'route:shop_http_request_duration_seconds:p99_rate5m' > /obs/queries/latency-panel.promql
obs-reload
