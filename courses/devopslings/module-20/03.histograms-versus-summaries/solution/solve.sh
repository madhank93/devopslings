#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
# Sum the bucket rates across replicas by le, then take the quantile.
# Runs in box.
set -euo pipefail
. /usr/local/lib/obs.sh
q='histogram_quantile(0.99, sum by (le) (rate(search_latency_hist_seconds_bucket[1m])))'
avg=$(prom_val '1000 * avg(search_latency_seconds{quantile="0.99"})')
fleet=$(prom_val "1000 * $q")
printf 'avg_p99_ms=%.0f\nfleet_p99_ms=%.0f\nerror_pct=%.0f\nquery=%s\n' "$avg" "$fleet" \
  "$(awk -v a="$avg" -v f="$fleet" 'BEGIN { print (a - f) / f * 100 }')" "$q" > /obs/answers/fleet-p99.txt
