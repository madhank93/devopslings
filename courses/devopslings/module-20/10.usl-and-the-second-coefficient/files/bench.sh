#!/usr/bin/env bash
# bench.sh NODES... — benchmark the indexer at each node count inside the
# checkout container; one JSON line per run. Run from sandboxes/chaos-stack.
# The quarter's budget is six runs, at 1 2 4 8 16 and 32 nodes.
set -euo pipefail
lesson=$(cd "$(dirname "$0")/.." && pwd)
dir=/srv/usl
for n in "$@"; do
  case "$n" in
    1|2|4|8|16|32) ;;
    *) echo "$n nodes is not in this quarter's benchmark budget: 1 2 4 8 16 32 only." >&2; exit 2 ;;
  esac
done
docker compose exec -T checkout mkdir -p $dir
docker compose cp "$lesson/files/bench.py" "checkout:$dir/bench.py" >/dev/null 2>&1
for n in "$@"; do
  docker compose exec -T -w "$dir" checkout timeout 60 python3 bench.py "$n"
done
