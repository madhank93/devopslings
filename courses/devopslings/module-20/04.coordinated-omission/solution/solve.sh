#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# An open-model test at production's arrival rate: requests keep arriving on
# schedule while search is paused, so the pause shows up in every request that
# waited for it. Runs on the host with cwd = sandboxes/chaos-stack.
set -euo pipefail
set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-20/*.coordinated-omission
lesson=$1
mkdir -p answers
cp "$lesson/solution/open.js" answers/open.js

run() {
  docker compose exec -T k6 sh -c 'cat > /tmp/s.js && k6 run --quiet --summary-export=/tmp/s.json /tmp/s.js >/dev/null 2>&1; cat /tmp/s.json' < "$1" |
    jq -r '.metrics.http_req_duration["p(99)"] | round'
}
cat > answers/coordinated-omission.txt <<EOF
closed_p99_ms=$(run "$lesson/files/report.js")
open_p99_ms=$(run answers/open.js)
EOF
