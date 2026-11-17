#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Times from the data, not the chat; the impact counted over the baseline;
# factors that are conditions (review, canary, alerting, rollback path), and
# one owned, dated action per factor.
set -euo pipefail
n=$(awk -F, 'NR > 1 && $1 >= "09:56" && $1 <= "10:51" { x += $3 - $2 * 0.002 } END { printf "%.0f", x }' /ha/sre/postmortem/errors.csv)
cat > /ha/answers/postmortem.txt <<TXT
impact_start: 09:56
detected: 10:00
resolved: 10:52
failed_checkouts: $n

timeline: 09:55 | checkout v412 deployed: payment client pool max 20 -> 4, per process
timeline: 09:56 | checkout failures rise above the usual 0.2% (4%)
timeline: 10:00 | CheckoutErrorRate pages at 8%
timeline: 10:04 | bob acknowledges the page
timeline: 10:05 | incident declared SEV2; alice commands, bob operates, carol communicates
timeline: 10:18 | error rate 41%; raised to SEV1
timeline: 10:35 | payment client connection pool found exhausted since the 09:55 deploy
timeline: 10:38 | decision to roll back; rollback (a rebuild of v411) starts
timeline: 10:44 | error rate 3% and falling
timeline: 10:52 | rollback complete; error rate back to 0.2%; resolved

factor: the pool size is set per process, and nothing in the config or its review shows that each process serves many workers
factor: the canary runs at low traffic and never exercises the payment step, so it passed a change that only fails under load
factor: no alert or dashboard watches payment client pool saturation; the first signal was customer-facing errors
factor: rollback is a rebuild of the previous version, so the decision at 10:38 took 14 minutes to reach customers

action: alice | payment client refuses to start if pool max is below its worker count | 2026-11-28
action: bob | canary runs a synthetic checkout through the payment step, at peak-like concurrency | 2026-12-05
action: bob | alert on payment pool wait time and saturation, before customer errors | 2026-11-28
action: gita | keep the previous build's image so rollback is a redeploy, not a rebuild, and time it | 2026-12-12
TXT
