#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
# Nearest rank on the sorted durations: the 500th, 950th and 990th.
# Runs in box.
set -euo pipefail
s=$(sort -g /obs/answers/durations.txt)
p99=$(sed -n 990p <<<"$s")
cat > /obs/answers/percentiles.txt <<TXT
p50=$(sed -n 500p <<<"$s")
p95=$(sed -n 950p <<<"$s")
p99=$p99
worse_than_p99=$(awk -v p="$p99" '$1 > p { n++ } END { print n + 0 }' <<<"$s")
query=quantile(0.99, search_test_request_duration_ms)
TXT
