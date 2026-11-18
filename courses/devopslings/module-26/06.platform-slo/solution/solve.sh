#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Good = a change deployed within 30 minutes; valid = every change that
# finished, failed ones included. The budget counts both over the hour.
set -euo pipefail
cat > /obs/prometheus/rules/platform-slo.yml <<'YML'
groups:
  - name: platform-slo
    rules:
      # Component health: useful for finding which part broke, not an SLI.
      - record: platform:availability:ratio
        expr: avg(platform_component_up{job="platform"})

      # Fraction of changes in the last minute that reached production within 30 minutes.
      - record: platform_journey:sli:ratio_1m
        expr: |
          sum(rate(platform_journey_duration_seconds_bucket{job="platform",le="1800.0"}[1m]))
            / sum(rate(platform_journeys_total{job="platform"}[1m]))

      # Share of the hour's error budget left, for a 99% objective: 1 untouched, 0 spent.
      - record: platform_journey:error_budget_remaining:1h
        expr: |
          1 - (
            1 - sum(increase(platform_journey_duration_seconds_bucket{job="platform",le="1800.0"}[1h]))
                  / sum(increase(platform_journeys_total{job="platform"}[1h]))
          ) / (1 - 0.99)
YML
obs-reload
