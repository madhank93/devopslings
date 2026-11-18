#!/usr/bin/env bash
# Stage 3's init: stage 1 working (the student's own, or the reference laid
# down and shipped), the SLO committed beside the code, and obs-stack's
# Prometheus scraping both load balancers.
set -euo pipefail
. "$DEVOPSLINGS_ROOT/courses/devopslings/module-27/files/lib.sh"
. "$DEVOPSLINGS_ROOT/courses/devopslings/module-27/03.stage-3-hold-the-line/files/common.sh"

mkdir -p "$S"
rm -f "$S/stage-1.log" "$S/last-experiment"
docker rm -f capstone-k6 >/dev/null 2>&1 || true
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Stage 2's health draw leaves checkout calling a pricing service; keep it
# answering, so a solved stage 2 is graded as solved.
git clone -q "$repo_url" "$work/before"
if grep -q '172.29.22.40' "$work/before/src/server.js" 2>/dev/null; then
  ( . "$M/02.stage-2-break-it/files/common.sh"; pricing_up )
fi
sql "delete from terraform_remote_state.states where name <> 'default'" >/dev/null

if [ -n "$(state_containers)" ] && bash "$M/files/stage-1-verify.sh" >"$S/stage-1.log" 2>&1; then
  echo "Stage 1 passes, so production is your pipeline and your deploy."
else
  echo "Stage 1 does not pass (scratch/stage-3-hold-the-line/stage-1.log says why):"
  echo "laying its reference solution down instead."
  bash "$M/files/seed.sh" >/dev/null
  bash "$M/files/solve.sh"
  jobs=$(wait_run "$(tip)" 0)
  if [ -z "$jobs" ] || printf '%s\n' "$jobs" | grep -qv ' success$'; then
    echo "stage 1's reference did not ship: ${jobs:-no pipeline ran}"
    exit 1
  fi
fi

git clone -q "$repo_url" "$work/checkout"
c="$work/checkout"
if ! cmp -s "$F/slo.yaml" "$c/slo.yaml"; then
  cp "$F/slo.yaml" "$c/slo.yaml"
  git -C "$c" add slo.yaml
  git -C "$c" -c user.email=devops@example.invalid -c user.name=devops \
    commit -qm "slo: the promise checkout makes, written down"
  git -C "$c" push -q origin HEAD:main
  wait_run "$(git -C "$c" rev-parse HEAD)" 0 >/dev/null
fi

prom_up

cat <<'Q'
checkout has an SLO now, in slo.yaml beside the code:

  availability  99.9% of requests through www answered without an error
  latency       p99 within 500ms

It has to hold in the minutes that matter: while a release goes out, and
while a replica is taken away. The check runs an experiment: customers at a
constant 40 requests a second for two and a half minutes; ten seconds in, the
grader pushes a release; once it is live, it stops one replica the way a host
being drained would (SIGTERM, then SIGKILL ten seconds later) and starts it
again when it has gone. Errors are counted by k6 and by the load balancers,
whichever is higher; the balancers' count is in Prometheus:

  http://localhost:19090/graph?g0.expr=sum(increase(haproxy_frontend_http_responses_total{proxy="www"}[5m]))%20by%20(code)

As it stands, the release pushes p99 to a second, and the stopped replica
burns about four times the error budget.

Q
