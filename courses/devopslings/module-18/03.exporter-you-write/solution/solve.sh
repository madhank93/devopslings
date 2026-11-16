#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# A custom collector reads /status on every scrape and mirrors the gateway's own
# lifetime counts as counters. The fetch has a timeout well under the 4s scrape
# timeout, and any failure reports gateway_up 0 instead of failing the scrape.
set -euo pipefail
cat > /obs/apps/gateway_exporter.py <<'PY'
"""gateway_exporter — Prometheus metrics for the payments gateway, on :9101."""
import json
import time
import urllib.request

from prometheus_client import start_http_server
from prometheus_client.core import REGISTRY, CounterMetricFamily, GaugeMetricFamily


class GatewayCollector:
    def collect(self):
        up = GaugeMetricFamily("gateway_up", "1 if the gateway's status page answered this scrape, else 0.")
        try:
            s = json.load(urllib.request.urlopen("http://gateway:8080/status", timeout=2))
        except Exception:
            up.add_metric([], 0)
            yield up
            return
        up.add_metric([], 1)
        yield up
        yield CounterMetricFamily("gateway_payments_processed", "Payments processed since the gateway was installed.",
                                  value=s["payments"]["processed"])
        yield CounterMetricFamily("gateway_payments_failed", "Payments that failed since the gateway was installed.",
                                  value=s["payments"]["failed"])
        yield GaugeMetricFamily("gateway_queue_depth", "Payments waiting to be processed.", value=s["queue_depth"])


REGISTRY.register(GatewayCollector())
start_http_server(9101)
while True:
    time.sleep(3600)
PY
