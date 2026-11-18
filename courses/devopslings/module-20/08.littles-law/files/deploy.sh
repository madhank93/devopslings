#!/usr/bin/env bash
# (Re)starts render inside the checkout container with WORKERS from .env. Run
# from sandboxes/chaos-stack. Exits 3 if it does not come up; its log is then
# /srv/littles-law/render.log in that container.
set -euo pipefail
lesson=$(cd "$(dirname "$0")/.." && pwd)
dir=/srv/littles-law
workers=$(grep -E '^WORKERS=' .env 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '" ' || true)

docker compose exec -T checkout sh -c "
  mkdir -p $dir
  p=\$(cat $dir/pid 2>/dev/null) || exit 0
  kill \"\$p\" 2>/dev/null || exit 0
  while kill -0 \"\$p\" 2>/dev/null; do sleep 0.1; done"
docker compose cp "$lesson/files/render.py" "checkout:$dir/render.py" >/dev/null 2>&1
docker compose exec -d -T -e WORKERS="$workers" checkout sh -c "cd $dir && echo \$\$ > pid && exec python3 render.py > render.log 2>&1"

for _ in $(seq 1 50); do
  docker compose exec -T checkout python3 -c \
    "import urllib.request; urllib.request.urlopen('http://localhost:8240/', timeout=3)" \
    >/dev/null 2>&1 && exit 0
  sleep 0.2
done
exit 3
