#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Nothing clever. Three single-pass awk programs over 64 MB, each of which
# names the field it means instead of searching the whole line for a number.
set -euo pipefail

log=/srv/logs/access.log
install -d /root/answers

# The quoted request is exactly three fields, so the status is $9. Anchoring
# with ^5[0-9][0-9]$ is what makes this a status count rather than a count of
# lines that happen to contain "503" — in a path, a byte count or a query
# string.
awk '$9 ~ /^5[0-9][0-9]$/ {n++} END {print n+0}' "$log" > /root/answers/q1

# Same filter, then tally the customer field. sort | uniq -c | sort -rn would
# do it too and is easier to remember; awk keeps it to one pass.
awk '$9 ~ /^5[0-9][0-9]$/ {c[$3]++} END {for (k in c) if (c[k] > best) {best = c[k]; who = k} print who}' \
  "$log" > /root/answers/q2

# $4 is "[02/Aug/2026:09:14:33". Characters 14-18 are HH:MM.
awk '{c[substr($4, 14, 5)]++} END {for (k in c) if (c[k] > best) {best = c[k]; when = k} print when}' \
  "$log" > /root/answers/q3
