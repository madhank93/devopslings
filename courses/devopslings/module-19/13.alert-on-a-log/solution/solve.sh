#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Page on the rate of failed payments across every pod: a declined card is
# one failure in two minutes, an outage is dozens a minute. `for` holds the
# page through a short spike; summing without `by` makes the outage one alert.
set -euo pipefail
cat > /obs/loki-rules/fake/rules.yaml <<'YML'
groups:
  - name: payments
    rules:
      - alert: PaymentsFailing
        expr: sum(rate({service="payments"} | json | level="error" [2m])) > 0.1
        for: 30s
        labels:
          severity: page
        annotations:
          summary: payments are failing at {{ $value | humanize }}/s across all pods
YML
