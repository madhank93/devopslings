#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

cat > /usr/local/bin/settle-orders <<'SH'
#!/bin/bash
# `pipefail` makes the pipeline's status the rightmost NON-ZERO status rather
# than simply the last one. Without it, `false | true` succeeds — and
# `fetch-ledger | grep | awk` succeeds whenever awk manages to process the
# nothing it was handed.
#
# `set -e` then acts on that status, and `-u` catches a typo'd variable name
# before it silently expands to empty.
set -euo pipefail

LEDGER=${LEDGER:-/srv/settle/ledger-$(date +%F).csv}
OUT=/srv/settle/settlement.out

# Write to a temporary file and move it into place only on success. A partial
# or empty output file that looks exactly like a real one is worse than no file
# at all — the next job downstream cannot tell them apart.
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

# grep exits 1 when it matches nothing, which under pipefail is a pipeline
# failure. Here that is the wanted behaviour: a ledger with no settled rows is
# not a successful settlement. If empty were legitimate, this is exactly where
# you would allow it explicitly rather than by accident.
fetch-ledger "$LEDGER" \
  | grep ',SETTLED,' \
  | awk -F, '{n++; t+=$4} END {printf "%d %.2f\n", n+0, t+0}' > "$tmp"

mv -- "$tmp" "$OUT"
trap - EXIT

echo "settle-orders: wrote $OUT"
SH
chmod 0755 /usr/local/bin/settle-orders
