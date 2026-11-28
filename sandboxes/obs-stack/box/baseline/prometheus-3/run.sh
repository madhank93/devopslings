#!/usr/bin/env bash
# The third Prometheus, and the flags it runs with. It starts held down; a
# lesson that needs it starts it. Saving this file restarts it; saving
# prometheus.yml does not (POST /-/reload, or obs-reload when a lesson says so).
exec prometheus \
  --config.file=/obs/prometheus-3/prometheus.yml \
  --storage.tsdb.path=/tmp/prometheus-3 \
  --storage.tsdb.retention.time=6h \
  --web.enable-lifecycle
