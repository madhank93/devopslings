#!/usr/bin/env bash
# Rolling deploy of orders-a then orders-b, started in the background by
# inject_fault. It waits for verify_done to signal that load is running, so the
# restarts always land inside the load test.
#
# usage: deploy.sh STATE_DIR COMPOSE_OVERRIDE   (cwd = sandboxes/chaos-stack)
set -u
S=$1
G=$2
dc() { docker compose -f compose.yaml -f "$G" "$@"; }
log() { echo "$(date +%s) $*" >>"$S/deploy.log"; }
lb_status() {
  curl -fsS --max-time 2 'http://127.0.0.1:18094/stats;csv' 2>/dev/null \
    | awk -F, -v s="$1" '$1=="orders" && $2==s {print $18}' || true
}

for _ in $(seq 240); do
  [ -f "$S/load-started" ] && break
  sleep 0.5
done
if [ ! -f "$S/load-started" ]; then
  log "abandoned: load never started"
  exit 0
fi
sleep 4

for r in a b; do
  t0=$(date +%s)
  log "stopping orders-$r"
  dc stop "orders-$r" >/dev/null 2>&1
  log "orders-$r stopped after $(($(date +%s) - t0))s"
  dc start "orders-$r" >/dev/null 2>&1
  # The balancer's status is stale until a check has run against the new process.
  sleep 1.5
  # Do not take the next replica down until the balancer is routing to this one.
  for _ in $(seq 60); do
    [ "$(lb_status "$r")" = UP ] && break
    sleep 0.5
  done
  log "orders-$r back in rotation: $(lb_status "$r")"
done
log "done"
