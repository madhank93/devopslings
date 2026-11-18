#!/usr/bin/env bash
# bench.sh LEDGER_PY NODES... — run bench.py inside the checkout container with
# LEDGER_PY as ledger.py, once per node count, 4 seconds each; one JSON line per
# run. Run from sandboxes/chaos-stack.
set -euo pipefail
lesson=$(cd "$(dirname "$0")/.." && pwd)
src=$1; shift
dir=/srv/the-knee/bench
docker compose exec -T checkout sh -c "rm -rf $dir && mkdir -p $dir"
for f in store.py bench.py; do docker compose cp "$lesson/files/$f" "checkout:$dir/$f" >/dev/null 2>&1; done
docker compose cp "$src" "checkout:$dir/ledger.py" >/dev/null 2>&1
for n in "$@"; do
  docker compose exec -T -w "$dir" checkout timeout 60 python3 bench.py "$n" 4
done
