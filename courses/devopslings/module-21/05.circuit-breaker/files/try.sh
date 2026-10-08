#!/usr/bin/env bash
# Deploy scratch/circuit-breaker/breaker.py into the checkout container beside
# the lesson's harness, restart it with a fresh Breaker, and send requests.
#
#   try.sh [N [GAP]]    N sequential requests (default 10), GAP seconds apart
#   try.sh burst N      N requests at once
#   try.sh 0            deploy only
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../../../.." && pwd)
dc() { docker compose -p devopslings-chaos-stack -f "$root/sandboxes/chaos-stack/compose.yaml" "$@"; }

dc exec -T checkout mkdir -p /opt/cb
dc cp "$here/checkout_cb.py" checkout:/opt/cb/checkout_cb.py >/dev/null 2>&1
dc cp "$here/probe.py" checkout:/opt/cb/probe.py >/dev/null 2>&1
dc cp "$root/scratch/circuit-breaker/breaker.py" checkout:/opt/cb/breaker.py >/dev/null 2>&1
dc exec -T checkout python3 /opt/cb/probe.py restart

case "${1:-10}" in
  0) ;;
  burst) dc exec -T checkout python3 /opt/cb/probe.py burst "${2:-10}" ;;
  *) dc exec -T checkout python3 /opt/cb/probe.py seq "${1:-10}" "${2:-0}" ;;
esac
