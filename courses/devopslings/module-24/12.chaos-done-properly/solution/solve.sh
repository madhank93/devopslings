#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Kill web2 for 30 seconds under load, watching the last 5 seconds of
# traffic; below 80% the experiment stops and repairs, and any exit repairs.
# The verdict is computed from the run, whichever way it went.
set -euo pipefail
cat > /ha/sre/chaos/experiment <<'SH'
#!/bin/bash
# experiment — lose web2 for 30s under customer traffic.
# Aborts if under 80% of the last 5 seconds' requests succeed. Always repairs.
set -u
target=web2 duration=30 abort=80
log=/ha/sre/chaos/runs/latest.log
load=
repair() {
  [ -n "$load" ] && kill "$load" 2>/dev/null
  node start "$target" >/dev/null 2>&1
  for _ in $(seq 40); do curl -sf -o /dev/null --max-time 1 "http://$target:8080/health" && break; sleep 0.5; done
}
trap 'repair; echo "interrupted: $target repaired"; exit 130' INT TERM
# Traffic first, so the run records the moment the node goes, not only after.
/ha/sre/chaos/load "$((duration + 2))" > "$log" &
load=$!
sleep 2
node kill "$target" >/dev/null
end=$((SECONDS + duration))
while [ "$SECONDS" -lt "$end" ] && kill -0 "$load" 2>/dev/null; do
  sleep 1
  ok=$(awk -v since="$(date +%s.%N)" 'BEGIN { since -= 5 } $1 > since { n++; if ($2 == 200) g++ }
    END { print (n < 20 ? 100 : 100 * g / n) }' "$log")
  if awk -v ok="$ok" -v a="$abort" 'BEGIN { exit !(ok < a) }'; then
    repair
    echo "aborted: ${ok}% of the last 5s succeeded, under $abort%; $target repaired"
    exit 3
  fi
done
wait "$load"
load=
repair
echo "done: $target was down ${duration}s; data in $log"
SH
chmod +x /ha/sre/chaos/experiment
/ha/sre/chaos/experiment
read -r n S span late < <(python3 /var/lib/devopslings/chaos-stats.py /ha/sre/chaos/runs/latest.log web2)
verdict=$(awk -v s="$S" 'BEGIN { print (s >= 99.5 ? "held" : "refuted") }')
cat > /ha/answers/chaos.txt <<TXT
target: web2
hypothesis: with web2 down, at least 99.5% of customer requests through www succeed
duration: 30
abort: 80
observed: $S
verdict: $verdict
TXT
