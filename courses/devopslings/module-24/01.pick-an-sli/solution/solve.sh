#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Candidate C, made precise: valid events are requests to the customer pages
# (so scanners and the batch export are not counted at all), and a good event
# is one that was not a 5xx and finished within 1000 ms (HAProxy's Ta timer).
set -euo pipefail
cat > /ha/sre/sli <<'SH'
#!/bin/bash
# SLI: good / valid over an HAProxy httplog read on stdin.
awk '{
  split($(NF-1), p, "?"); path = p[1]
  if (path != "/" && path != "/cart" && path != "/orders") next
  split($5, t, "/"); valid++
  if ($6 < 500 && t[5] <= 1000) good++
} END { printf "%.4f\n", valid ? good / valid : 1 }'
SH
chmod +x /ha/sre/sli
