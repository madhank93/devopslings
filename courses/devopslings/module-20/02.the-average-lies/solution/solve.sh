#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
# Mean from _sum / _count; the slow share is everything above bucket le="1.0".
# Runs in box.
set -euo pipefail
. /usr/local/lib/obs.sh
M=profile_request_duration_seconds
mean=$(prom_val "1000 * sum(rate(${M}_sum[1m])) / sum(rate(${M}_count[1m]))")
slow=$(prom_val "100 * (1 - sum(rate(${M}_bucket{le=~\"1|1.0\"}[1m])) / sum(rate(${M}_count[1m])))")
printf 'mean_ms=%.0f\naffected_users_pct=%.1f\n' "$mean" "$slow" > /obs/answers/average.txt
