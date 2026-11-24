#!/usr/bin/env bash
# The second Prometheus, and the flags it runs with. It starts held down; a
# lesson that needs it starts it. Saving this file restarts it; saving
# prometheus.yml does not (POST /-/reload, or obs-reload when a lesson says so).
exec prometheus \
  --config.file=/obs/prometheus-2/prometheus.yml \
  --storage.tsdb.path=/tmp/prometheus-2 \
  --storage.tsdb.retention.time=6h \
  --web.enable-lifecycle
