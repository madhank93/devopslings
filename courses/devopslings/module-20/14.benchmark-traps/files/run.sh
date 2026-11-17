#!/usr/bin/env bash
# run.sh BENCH_PY [RUNS] — run a benchmark the way the CI benchmark job does:
# inside the checkout container, pinned to core 1, RUNS times (default 5),
# each in a fresh process. Prints each run's number. Run from
# sandboxes/chaos-stack.
set -euo pipefail
lesson=$(cd "$(dirname "$0")/.." && pwd)
src=$1; runs=${2:-5}
dir=/srv/benchmark-traps
docker compose exec -T checkout mkdir -p "$dir"
for f in catalog.py workload.py; do docker compose cp "$lesson/files/$f" "checkout:$dir/$f" >/dev/null 2>&1; done
docker compose cp "$src" "checkout:$dir/bench.py" >/dev/null 2>&1
# The CI host is never idle: a busy core 0 holds the CPU clock steady, which
# otherwise moves the number between runs as much as the code does.
docker compose exec -d -T -w "$dir" checkout sh -c 'echo $$ > clock.pid; exec timeout 600 taskset -c 0 python3 -c "while 1: pass"'
trap 'docker compose exec -T checkout sh -c "kill \$(cat $dir/clock.pid) 2>/dev/null; rm -f $dir/clock.pid" || true' EXIT
sleep 0.5
for _ in $(seq 1 "$runs"); do
  docker compose exec -T -w "$dir" -e CATALOG_SLOW="${CATALOG_SLOW:-}" -e PYTHONDONTWRITEBYTECODE=1 checkout \
    timeout 60 taskset -c 1 python3 bench.py 2>&1 | tail -1
done
