#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The lock was held through a 5ms rates call that never touches the balance,
# so every node queued behind it. Moving the call out shrinks the critical
# section to the row's read and write. Runs on the host with cwd =
# sandboxes/chaos-stack.
set -euo pipefail
set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-20/*.the-knee
cp "$1/solution/ledger.py" answers/ledger.py
peak=$(docker compose exec -T checkout cat /srv/the-knee/baseline.json |
  jq -s 'max_by(.entries_per_s) | .nodes')
printf 'peak_nodes=%s\n' "$peak" > answers/the-knee.txt
