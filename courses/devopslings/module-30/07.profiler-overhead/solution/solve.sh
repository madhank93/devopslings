#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The profiler's cost is per sample, so it scales with the rate. 50 Hz keeps
# its share of the one CPU well under 2% and still gives enough samples to rank
# functions. The overhead written down is the one --bench measures.
set -euo pipefail
mkdir -p /obs/answers
sed -i 's/^sample_rate = .*/sample_rate = 50/' /obs/quotes/profiling.ini
cost=$(taskset -c 0 python3 /obs/quotes/service.py --bench 5 | jq -r .profiler_cpu_percent)
printf 'sample_rate=50\noverhead_percent=%s\n' "$cost" > /obs/answers/overhead.txt
