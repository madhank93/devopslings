#!/usr/bin/env bash
# The drill's game day.
#
#   gameday.sh start   (re)start metered pricing and shop from .env, reset the proxies
#   gameday.sh run     replay the incident under load and print the report
#   gameday.sh         both
#
# `start` fails only when the harness cannot come up. A shop that will not
# start on the settings in .env is reported, and left for the check to explain.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../../../.." && pwd)
sb="$root/sandboxes/chaos-stack"
S="$root/scratch/resilience-triage-drill"
dc() { docker compose -p devopslings-chaos-stack -f "$sb/compose.yaml" "$@"; }
tp=http://127.0.0.1:8474
KNOBS="PRICING_TIMEOUT PRICING_POOL FALLBACK_PRICE RETRY_MAX_ATTEMPTS RETRY_ON BREAKER_THRESHOLD BREAKER_COOLDOWN_S RECS_URL"
env_val() { grep -E "^$1=" "$sb/.env" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"\r' | xargs || true; }

stop() {
  dc exec -T "$1" sh -c '
    p=$(cat /tmp/triage-'"$2"'.pid 2>/dev/null) || exit 0
    kill "$p" 2>/dev/null || exit 0
    while kill -0 "$p" 2>/dev/null; do sleep 0.1; done' || true
}
up() {
  for _ in $(seq 1 50); do
    dc exec -T "$1" python3 -c \
      "import urllib.request; urllib.request.urlopen('http://localhost:8214/$2', timeout=1)" \
      >/dev/null 2>&1 && return 0
    sleep 0.2
  done
  return 1
}

start() {
  dc exec -T pricing mkdir -p /opt/triage
  dc exec -T checkout mkdir -p /opt/triage
  dc cp "$here/ledger.py" pricing:/opt/triage/ledger.py >/dev/null 2>&1
  dc cp "$here/shop.py" checkout:/opt/triage/shop.py >/dev/null 2>&1
  dc cp "$here/report.py" checkout:/opt/triage/report.py >/dev/null 2>&1

  stop pricing ledger
  stop checkout shop
  dc exec -d -T pricing sh -c \
    'echo $$ > /tmp/triage-ledger.pid; cd /opt/triage; exec python3 ledger.py > ledger.log 2>&1'
  envs=()
  for k in $KNOBS; do envs+=(-e "$k=$(env_val "$k")"); done
  dc exec -d -T "${envs[@]}" checkout sh -c \
    'echo $$ > /tmp/triage-shop.pid; cd /opt/triage; exec python3 -u shop.py > shop.log 2>&1'

  for p in triage-pricing triage-recs; do
    curl -fsS -X DELETE "$tp/proxies/$p" >/dev/null 2>&1 || true
  done
  curl -fsS -X POST "$tp/proxies" -H 'Content-Type: application/json' \
    -d '{"name":"triage-pricing","listen":"0.0.0.0:21214","upstream":"pricing:8214"}' >/dev/null
  # Recommendations were decommissioned; the proxy stays, refusing connections.
  curl -fsS -X POST "$tp/proxies" -H 'Content-Type: application/json' \
    -d '{"name":"triage-recs","listen":"0.0.0.0:21215","upstream":"pricing:8215","enabled":false}' >/dev/null

  up pricing stats || { echo "metered pricing did not start on pricing:8214"; return 1; }
  if ! up checkout health; then
    echo "shop did not start with the settings in sandboxes/chaos-stack/.env:"
    dc exec -T checkout tail -5 /opt/triage/shop.log 2>/dev/null | sed 's/^/  /' || true
  fi
}

run() {
  mkdir -p "$S"
  rc=0
  out=$(dc exec -T k6 k6 run --quiet --log-output=none - < "$here/gameday.js" 2>&1) || rc=$?
  rep=$(dc exec -T checkout python3 /opt/triage/report.py 2>&1) || true
  printf '%s\n%s\n' "$out" "$rep" | grep '^kv ' | cut -c4- > "$S/last-run" || true
  echo "game day — the pricing incident, replayed against shop"
  echo
  printf '%s\n' "$rep" | grep -v '^kv ' || true
  echo
  printf '%s\n' "$out" | grep -v '^kv ' || true
  return "$rc"
}

case "${1:-all}" in
  start) start ;;
  run) run ;;
  all) start && run ;;
  *) echo "usage: gameday.sh [start|run]" >&2; exit 2 ;;
esac
