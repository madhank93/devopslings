#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Three panels, one per stated question, each filtered on the env variable,
# which lists the environments Prometheus actually has for shop.
set -euo pipefail
cat > /obs/grafana/dashboards/shop.json <<'JSON'
{
  "uid": "shop",
  "title": "Shop overview",
  "time": {"from": "now-1h", "to": "now"},
  "refresh": "10s",
  "templating": {"list": [{
    "name": "env", "label": "Environment", "type": "query",
    "datasource": {"type": "prometheus", "uid": "prometheus"},
    "query": "label_values(shop_http_requests_total, env)",
    "refresh": 2, "current": {"text": "prod", "value": "prod"}
  }]},
  "panels": [
    {"id": 1, "type": "stat", "title": "Is shop serving? Requests per second",
     "gridPos": {"x": 0, "y": 0, "w": 8, "h": 6}, "fieldConfig": {"defaults": {"unit": "reqps"}},
     "datasource": {"type": "prometheus", "uid": "prometheus"},
     "targets": [{"refId": "A", "expr": "sum(rate(shop_http_requests_total{env=\"$env\"}[$__rate_interval]))"}]},
    {"id": 2, "type": "stat", "title": "What fraction fails?",
     "gridPos": {"x": 8, "y": 0, "w": 8, "h": 6}, "fieldConfig": {"defaults": {"unit": "percentunit"}},
     "datasource": {"type": "prometheus", "uid": "prometheus"},
     "targets": [{"refId": "A", "expr": "sum(rate(shop_http_requests_total{env=\"$env\",code=~\"5..\"}[$__rate_interval])) / sum(rate(shop_http_requests_total{env=\"$env\"}[$__rate_interval]))"}]},
    {"id": 3, "type": "timeseries", "title": "How slow is the slowest 1%? p99 latency",
     "gridPos": {"x": 16, "y": 0, "w": 8, "h": 6}, "fieldConfig": {"defaults": {"unit": "s"}},
     "datasource": {"type": "prometheus", "uid": "prometheus"},
     "targets": [{"refId": "A", "expr": "histogram_quantile(0.99, sum by (le) (rate(shop_http_request_duration_seconds_bucket{env=\"$env\"}[$__rate_interval])))"}]}
  ],
  "schemaVersion": 41
}
JSON
