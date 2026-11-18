#!/usr/bin/env bash
# (Re)starts quote inside the checkout container, under a loop that restarts
# it whenever it is killed, and clears the restart count. Run from
# sandboxes/chaos-stack. Exits 3 if it does not come up.
set -euo pipefail
lesson=$(cd "$(dirname "$0")/.." && pwd)
dir=/srv/load-shapes

# checkout's PID 1 does not reap orphans, so a killed quote lingers as a zombie:
# wait for that state rather than for the pid to vanish.
docker compose exec -T checkout sh -c "
  mkdir -p $dir
  kill \$(cat $dir/pid 2>/dev/null) 2>/dev/null
  c=\$(cat $dir/child 2>/dev/null)
  [ -n \"\$c\" ] && kill \$c 2>/dev/null && while grep -qs '^State:.*[^Z] (' /proc/\$c/status; do sleep 0.1; done
  rm -f $dir/restarts $dir/child" || true
docker compose cp "$lesson/files/quote.py" "checkout:$dir/quote.py" >/dev/null 2>&1
docker compose exec -d -T checkout sh -c "cd $dir && echo \$\$ > pid && while :; do python3 quote.py >> quote.log 2>&1 & echo \$! > child; wait \$!; date +%s >> restarts; sleep 1; done"

for _ in $(seq 1 50); do
  docker compose exec -T checkout python3 -c \
    "import urllib.request; urllib.request.urlopen('http://localhost:8250/stats', timeout=3)" \
    >/dev/null 2>&1 && exit 0
  sleep 0.2
done
exit 3
