#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Totals over the 30 days, then the night outage found in the data: the
# first and last minute before 06:00 on 26 October where two or more
# requests failed. A stray failure is the background, not the outage.
set -euo pipefail
csv=/ha/sre/requests-30d.csv
read -r v g first last < <(awk -F, 'NR > 1 { v += $2; g += $3 }
  $1 ~ /^2026-10-26T0[0-5]/ && $2 - $3 >= 2 { if (!f) f = $1; l = $1 }
  END { print v, g, f, l }' "$csv")
read -r iv ig < <(awk -F, -v a="$first" -v b="$last" '$1 >= a && $1 <= b { v += $2; g += $3 } END { print v, g }' "$csv")
awk -v v="$v" -v g="$g" -v iv="$iv" -v ig="$ig" 'BEGIN {
  b = v * 0.005; f = v - g; ib = iv - ig
  printf "valid_requests: %d\nerror_budget_requests: %.1f\nfailed_requests: %d\n", v, b, f
  printf "budget_remaining_percent: %.2f\n", (b - f) / b * 100
  printf "night_incident_budget_percent: %.3f\n", ib / b * 100
  printf "night_incident_burn_rate: %.1f\n", (ib / iv) / 0.005
}' > /ha/answers/budget.txt
cat /ha/answers/budget.txt
