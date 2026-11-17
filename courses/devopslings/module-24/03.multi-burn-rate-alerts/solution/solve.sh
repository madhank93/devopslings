#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The Workbook's multiwindow, multi-burn-rate alerts for a 99.9% SLO: page
# at 14.4x over 1h and 5m, or 6x over 6h and 30m; ticket at 1x over 3d and
# 6h. The short window lets each alert resolve soon after the burn stops.
set -euo pipefail
cat > /obs/prometheus/rules/slo-burn.yml <<'YML'
groups:
  - name: shop-slo
    rules:
      - record: shop:error_ratio:rate5m
        expr: sum(rate(shop_http_requests_total{job="shop",code=~"5.."}[5m])) / sum(rate(shop_http_requests_total{job="shop"}[5m]))
      - record: shop:error_ratio:rate30m
        expr: sum(rate(shop_http_requests_total{job="shop",code=~"5.."}[30m])) / sum(rate(shop_http_requests_total{job="shop"}[30m]))
      - record: shop:error_ratio:rate1h
        expr: sum(rate(shop_http_requests_total{job="shop",code=~"5.."}[1h])) / sum(rate(shop_http_requests_total{job="shop"}[1h]))
      - record: shop:error_ratio:rate6h
        expr: sum(rate(shop_http_requests_total{job="shop",code=~"5.."}[6h])) / sum(rate(shop_http_requests_total{job="shop"}[6h]))
      - record: shop:error_ratio:rate3d
        expr: sum(rate(shop_http_requests_total{job="shop",code=~"5.."}[3d])) / sum(rate(shop_http_requests_total{job="shop"}[3d]))
      - alert: ShopBudgetFastBurn
        expr: |
          (shop:error_ratio:rate1h > 14.4 * 0.001 and shop:error_ratio:rate5m > 14.4 * 0.001)
          or
          (shop:error_ratio:rate6h > 6 * 0.001 and shop:error_ratio:rate30m > 6 * 0.001)
        for: 2m
        labels: {severity: page}
      - alert: ShopBudgetSlowBurn
        expr: shop:error_ratio:rate3d > 1 * 0.001 and shop:error_ratio:rate6h > 1 * 0.001
        for: 1h
        labels: {severity: ticket}
YML
chmod a+r /obs/prometheus/rules/slo-burn.yml
obs-reload >/dev/null
