#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The profiler's cost is per sample: at 1000 Hz its threads take ~13% of the
# one CPU, at 100 Hz ~1.5%, at 50 Hz under 1%. 50 Hz keeps a 5-second window at
# 250 samples, plenty to rank functions. Throughput on against off, alternated
# under taskset -c 0, agrees with the per-thread CPU figure.
set -euo pipefail
mkdir -p /obs/answers
sed -i 's/^sample_rate = .*/sample_rate = 50/' /obs/quotes/profiling.ini
printf 'sample_rate=50\noverhead_percent=0.9\n' > /obs/answers/overhead.txt
