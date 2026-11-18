#!/usr/bin/env bash
# (Re)starts the shards and the page inside the checkout container with the
# settings in .env. Run from sandboxes/chaos-stack. Exits 3 if the page does not
# come up; its log is then /srv/fan-out/page.log in that container.
set -euo pipefail
lesson=$(cd "$(dirname "$0")/.." && pwd)
dir=/srv/fan-out
env_val() { grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || true; }

docker compose exec -T checkout sh -c "
  mkdir -p $dir
  for p in \$(cat $dir/*.pid 2>/dev/null); do
    kill \"\$p\" 2>/dev/null || continue
    while kill -0 \"\$p\" 2>/dev/null; do sleep 0.1; done
  done"
for f in shards.py page.py; do docker compose cp "$lesson/files/$f" "checkout:$dir/$f" >/dev/null 2>&1; done
docker compose exec -d -T checkout sh -c "cd $dir && echo \$\$ > shards.pid && exec python3 shards.py > shards.log 2>&1"
docker compose exec -d -T -e FANOUT="$(env_val FANOUT)" -e HEDGE_AFTER_MS="$(env_val HEDGE_AFTER_MS)" \
  checkout sh -c "cd $dir && echo \$\$ > page.pid && exec python3 page.py > page.log 2>&1"

for _ in $(seq 1 50); do
  docker compose exec -T checkout python3 -c \
    "import urllib.request; urllib.request.urlopen('http://localhost:8220/', timeout=5)" \
    >/dev/null 2>&1 && exit 0
  sleep 0.2
done
exit 3
