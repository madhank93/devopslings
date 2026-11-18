#!/usr/bin/env bash
# neighbour.sh start|restart|stop|cont — the search reindex job on core 1 of
# the checkout container. start leaves a running one alone; stop and cont pause
# and resume it. Run from sandboxes/chaos-stack.
set -euo pipefail
lesson=$(cd "$(dirname "$0")/.." && pwd)
dir=/srv/benchmark-traps
# Its pids, if all three workers are alive.
pids() { docker compose exec -T checkout sh -c "p=\$(cat $dir/reindex.pid 2>/dev/null) && [ \$(echo \$p | wc -w) = 3 ] && kill -0 \$p 2>/dev/null && echo \$p" || true; }
p=$(pids)
case $1 in
  restart|start)
    if [ -n "$p" ] && [ "$1" = start ]; then exit 0; fi
    docker compose exec -T checkout sh -c "kill -9 \$(cat $dir/reindex.pid 2>/dev/null) 2>/dev/null; mkdir -p $dir && rm -f $dir/reindex.pid" || true
    docker compose cp "$lesson/files/reindex.py" "checkout:$dir/reindex.py" >/dev/null 2>&1
    docker compose exec -d -T -w "$dir" checkout python3 reindex.py
    sleep 1 ;;
  stop) [ -z "$p" ] || docker compose exec -T checkout sh -c "kill -STOP $p" ;;
  cont) [ -z "$p" ] || docker compose exec -T checkout sh -c "kill -CONT $p" ;;
esac
