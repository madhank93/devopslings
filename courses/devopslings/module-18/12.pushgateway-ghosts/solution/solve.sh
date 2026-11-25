#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Page on the age of the last push. A run lands every 20 to 26 seconds, so 60
# seconds is two missed runs, and a job that never pushed still pages through
# absent().
set -euo pipefail
cat > /obs/prometheus/rules/nightly.yml <<'YML'
groups:
  - name: nightly
    rules:
      - alert: NightlyLate
        expr: time() - push_time_seconds{job="nightly"} > 60
        labels:
          severity: critical
        annotations:
          summary: the nightly job has not completed a run for two schedules
      - alert: NightlyNeverPushed
        expr: absent(push_time_seconds{job="nightly"})
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: the Pushgateway has nothing from the nightly job
YML
obs-reload
