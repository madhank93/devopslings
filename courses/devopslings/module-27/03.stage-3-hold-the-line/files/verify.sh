#!/usr/bin/env bash
# Stage 3's check: an experiment under constant load (a release, then a
# replica stopped), graded against the SLO from HAProxy's own counters and the
# customers' latency; the stopped replica's shutdown graded as 21/09 grades
# one; then all of stage 1.
set -euo pipefail
. "$DEVOPSLINGS_ROOT/courses/devopslings/module-27/files/lib.sh"
. "$DEVOPSLINGS_ROOT/courses/devopslings/module-27/03.stage-3-hold-the-line/files/common.sh"

work=$(mktemp -d)
head_sha=""
pushed=""
stopped=""
cleanup() {
  docker rm -f capstone-k6 >/dev/null 2>&1 || true
  [ -z "$stopped" ] || docker start "$stopped" >/dev/null 2>&1 || true
  if [ -n "$pushed" ]; then
    git -C "$work/checkout" push -q --force origin "${head_sha}:main" >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

if ! git clone -q "$repo_url" "$work/checkout" 2>/dev/null; then
  echo "not yet: could not clone ${repo}"
  exit 1
fi
cd "$work/checkout"
git config user.email grader@example.invalid
git config user.name grader
head_sha=$(git rev-parse HEAD)

# The promise is not a setting.
avail=$(sed -n 's/^availability_percent:[[:space:]]*\([0-9.]*\).*/\1/p' slo.yaml 2>/dev/null | head -1)
p99=$(sed -n 's/^latency_p99_ms:[[:space:]]*\([0-9.]*\).*/\1/p' slo.yaml 2>/dev/null | head -1)
if [ "$avail" != "$SLO_AVAILABILITY" ] || [ "$p99" != "$SLO_P99_MS" ]; then
  echo "not yet: slo.yaml says availability ${avail:-nothing}% and p99 ${p99:-nothing}ms; the SLO"
  echo "is ${SLO_AVAILABILITY}% and ${SLO_P99_MS}ms. It is what customers were promised, so a bigger"
  echo "error budget is a different promise, not a fix. The grader holds production to the"
  echo "original either way."
  exit 1
fi

# Whatever was pushed last has to finish deploying before the experiment.
wait_run "$head_sha" 0 >/dev/null
for s in shop1 shop2; do
  for _ in $(seq 20); do
    case "$(lb_status lb1 "$s")/$(lb_status lb2 "$s")" in UP/UP) break ;; esac
    sleep 1
  done
  case "$(lb_status lb1 "$s")/$(lb_status lb2 "$s")" in UP/UP) ;; *)
    echo "not yet: before the experiment, lb1 and lb2 list ${s} as" \
         "'$(lb_status lb1 "$s")' and '$(lb_status lb2 "$s")'. Stage 1 has to hold first."
    exit 1 ;;
  esac
done

# ---- the experiment --------------------------------------------------------
t0=$(date +%s)
capstone_event stage-3 experiment_start
docker create --name capstone-k6 --network devopslings-ha-stack_front \
  --add-host www:172.29.22.100 -e DURATION=150s grafana/k6:0.54.0 run --quiet /tmp/load.js >/dev/null
docker cp "$F/load.js" capstone-k6:/tmp/load.js
docker start capstone-k6 >/dev/null
sleep 10

# A release: a new VERSION and nothing else.
release="release-$(date +%s)"
sed -i.bak "s/const VERSION = \"[^\"]*\"/const VERSION = \"${release}\"/" src/server.js
rm -f src/server.js.bak
git add -A
git commit -qm "grader: ${release}"
pushed=1
git push -q origin HEAD:main
t_rel=$(date +%s)
capstone_event stage-3 release_pushed "$release"
jobs=$(wait_run "$(git rev-parse HEAD)" 0)
t_rel_done=$(date +%s)
bad=$(printf '%s\n' "$jobs" | grep -v ' success$' | head -1 || true)
if [ -z "$jobs" ] || [ -n "$bad" ]; then
  echo "not yet: the release's pipeline did not succeed: job '${bad% *}' ended '${bad##* }'."
  exit 1
fi
if [ $((t_rel_done - t0)) -gt 115 ]; then
  echo "not yet: the release took $((t_rel_done - t_rel))s from push to finished pipeline, so the"
  echo "experiment ran out before the grader could stop a replica. Keep a release under"
  echo "about 90 seconds."
  exit 1
fi
live=""
for _ in $(seq 10); do
  live=$(ops curl -fsS --max-time 2 http://www/ 2>/dev/null | jq_ops -r '.version // empty' 2>/dev/null || true)
  [ "$live" = "$release" ] && break
  sleep 1
done
if [ "$live" != "$release" ]; then
  echo "not yet: the release's pipeline is green, but www answers '${live}', not ${release}."
  exit 1
fi
sleep 5

# A replica taken away the way a drained host takes it: SIGTERM, then SIGKILL
# ten seconds later. What it answers meanwhile is recorded twice a second.
victim=$(state_containers | tail -1)
vname=${victim% *}
stopped=${victim#* }
vip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$stopped")
ops sh -c "for i in \$(seq 60); do
  h=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 http://${vip}:8080/health)
  r=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 http://${vip}:8080/)
  echo \"\$h \$r\"
  [ \"\$h\$r\" = 000000 ] && break
  sleep 0.5
done" > "$work/shutdown.log" 2>&1 &
watcher=$!
sleep 1
t_kill=$(date +%s)
capstone_event stage-3 replica_killed "$vname"
docker stop -t 10 "$stopped" >/dev/null
t_gone=$(date +%s)
wait "$watcher" || true
docker start "$stopped" >/dev/null
stopped=""

docker wait capstone-k6 >/dev/null
t_end=$(date +%s)
k6log=$(docker logs capstone-k6 2>&1 || true)
summary=$(printf '%s\n' "$k6log" | grep '^{' | tail -1 || true)
docker rm -f capstone-k6 >/dev/null
reqs=$(printf '%s' "$summary" | jq_ops -r '.reqs // 0' 2>/dev/null || echo 0)
failed=$(printf '%s' "$summary" | jq_ops -r '.failed // 0' 2>/dev/null || echo 0)
p99_ms=$(printf '%s' "$summary" | jq_ops -r '.p99 // 0' 2>/dev/null || echo 0)

# HAProxy's count of what it answered with an error, over the window, from
# both load balancers (only the VIP holder takes traffic). One scrape later,
# so the last seconds are in.
sleep 6
win=$(( $(date +%s) - t0 + 5 ))
errors=$(promq "sum(increase(haproxy_frontend_http_responses_total{job=\"capstone-haproxy\",proxy=\"www\",code=\"5xx\"}[${win}s]))")
total=$(promq "sum(increase(haproxy_frontend_http_requests_total{job=\"capstone-haproxy\",proxy=\"www\"}[${win}s]))")
errors=$(awk -v e="${errors:-0}" 'BEGIN { printf "%d", e + 0.5 }')
# A request that never got an answer at all is not in HAProxy's counters.
[ "$failed" -gt "$errors" ] && errors=$failed
budget=$(awk -v n="$reqs" -v a="$SLO_AVAILABILITY" 'BEGIN { printf "%.1f", n * (100 - a) / 100 }')
burn=$(awk -v e="$errors" -v b="$budget" 'BEGIN { printf "%.2f", (b > 0 ? e / b : 0) }')
capstone_event stage-3 experiment_end "p99_ms=${p99_ms} error_budget_burn=${burn}"
printf 'reqs=%s errors=%s haproxy_total=%s p99_ms=%s burn=%s\n' "$reqs" "$errors" "${total:-?}" "$p99_ms" "$burn" \
  > "$DEVOPSLINGS_ROOT/scratch/stage-3-hold-the-line/last-experiment"

# When failures (or slow answers) happened, against the release and the stop:
# k6 logs each one's second, which also covers requests HAProxy never answered.
# Prints "release", "stop", or both.
phases() {
  { printf '%s\n' "$k6log" | grep -o "$1 [0-9]*" || true; } | awk '{ print $2 }' | sort -u |
    awk -v r0="$t_rel" -v r1=$((t_rel_done + 8)) -v k0="$t_kill" -v k1=$((t_gone + 8)) '
      $1 >= r0 && $1 <= r1 { rel = 1 }
      $1 >= k0 && $1 <= k1 { stop = 1 }
      END { printf "%s%s", (rel ? "release " : ""), (stop ? "stop" : "") }'
}
during=$(phases fail)
slow_during=$(phases slow)

if [ "$reqs" -lt 1000 ]; then
  echo "not yet: the load test made only ${reqs:-no} requests; it did not run as planned:"
  printf '%s\n' "$k6log" | tail -5
  exit 1
fi
if awk -v e="$errors" -v b="$budget" 'BEGIN { exit !(e > b) }'; then
  echo "not yet: ${errors} of ${reqs} requests failed during the experiment. The SLO allows"
  echo "${budget} (${SLO_AVAILABILITY}%), so the window burned ${burn}x its error budget."
  case "$during" in
    *release*stop*|*stop*release*)
      echo "The errors came both while the release rolled out and while ${vname} was stopped." ;;
    *release*)
      echo "The errors came while the release rolled out (${t_rel}s to $((t_rel_done + 8))s, epoch)."
      echo "Look at what happens to each replica during a deploy, and what the balancers"
      echo "are sending it at that moment." ;;
    *stop*)
      echo "The errors came while ${vname} was being stopped. A replica that is told to stop"
      echo "can tell the balancers first." ;;
  esac
  case "$slow_during" in *release*)
    echo "Customers also waited over ${SLO_P99_MS}ms during the release; p99 is graded next." ;;
  esac
  exit 1
fi
if [ "$p99_ms" -gt "$SLO_P99_MS" ]; then
  echo "not yet: no more errors than the budget allows, but p99 was ${p99_ms}ms; the SLO"
  echo "is ${SLO_P99_MS}ms."
  case "$slow_during" in
    *release*stop*) echo "The slow answers came both while the release rolled out and while ${vname} was stopped." ;;
    *release*)
      echo "The slow answers came while the release rolled out: requests waiting on a"
      echo "replica that was being replaced." ;;
    *stop*) echo "The slow answers came while ${vname} was being stopped." ;;
  esac
  if docker exec devopslings-ha-ops grep -Eq '^[[:space:]]*(timeout|retries)' /ha/haproxy.cfg; then
    echo "/ha/haproxy.cfg sets its own timeouts or retries. A longer wait turns an error into"
    echo "a slow answer: it is still a customer the promise was broken for."
  fi
  exit 1
fi

# The stopped replica's shutdown, as 21/09 grades one: it has to stop
# passing its health check while it is still serving.
if ! awk '$1 != "200" && $1 != "000" && $2 == "200" { found = 1 } END { exit !found }' "$work/shutdown.log"; then
  echo "not yet: the SLO held, but when the grader stopped ${vname} it answered /health"
  echo "with 200 until it stopped answering at all:"
  uniq -c "$work/shutdown.log" | sed 's/^ */  /; s/$/   (count, \/health, \/)/' | head -6
  echo "The balancers only learn a replica is going from failed checks, after it has gone."
  echo "On SIGTERM, fail the check first, keep serving until they have noticed, then exit."
  exit 1
fi

# ---- then stage 1, on the student's own commit ------------------------------
git push -q --force origin "${head_sha}:main"
pushed=""
if ! out=$(bash "$M/files/stage-1-verify.sh" 2>&1); then
  printf '%s\n' "$out"
  exit 1
fi

echo "PASS: ${reqs} requests through a release and a stopped replica: ${errors} failed"
echo "(budget ${budget}), p99 ${p99_ms}ms. The stopped replica left rotation before it left."
