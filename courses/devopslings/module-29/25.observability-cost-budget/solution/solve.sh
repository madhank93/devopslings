#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Traces: every error trace plus 10% of the rest, for the 14 days incident
# reviews need. Logs: stop ingesting debug, which is over half the volume.
# Metrics: drop the per-user label and keep 35 days, enough for a 28-day SLO.
#   traces  6,000 x (0.02 + 0.98 x 0.10) = 708M x (1.00 + 0.05 x 14)   = $1,204
#   logs    30,000 x 45% = 13,500 GB x (0.15 + 0.005 x 30)             = $4,050
#   metrics 1,200,000 x (0.0006 + 0.00002 x 35)                         = $1,560
set -euo pipefail
cat > /obs/answers/plan.yaml <<'YML'
traces:
  sample_percent: 10
  retention_days: 14
  cost: 1204
  loses: latency questions about successful requests are answered from metrics now; nine in ten non-error requests have no trace, and nothing older than two weeks can be compared
logs:
  drop_levels: [debug]
  retention_days: 30
  cost: 4050
  loses: debug lines were the only record of a request's internal decisions; reproducing a bug now needs debug turned on for that service after the fact
metrics:
  max_series: 1200000
  retention_days: 35
  cost: 1560
  loses: latency for one particular user is no longer a query, it has to come from that user's traces or logs; trends and capacity comparisons older than five weeks are gone
total: 6814
YML
