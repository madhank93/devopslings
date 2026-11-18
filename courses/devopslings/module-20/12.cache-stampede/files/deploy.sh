#!/usr/bin/env bash
# (Re)starts catalog-db and the catalog API inside the checkout container, with
# answers/cache.py as the API's cache. Run from sandboxes/chaos-stack. Exits 3
# if the API does not come up; its log is then /srv/cache-stampede/api.log in
# that container.
set -euo pipefail
lesson=$(cd "$(dirname "$0")/.." && pwd)
dir=/srv/cache-stampede

docker compose exec -T checkout sh -c "
  mkdir -p $dir
  for p in \$(cat $dir/*.pid 2>/dev/null); do
    kill \"\$p\" 2>/dev/null || continue
    while kill -0 \"\$p\" 2>/dev/null; do sleep 0.1; done
  done
  rm -f $dir/cache.py"
for f in origin.py api.py; do docker compose cp "$lesson/files/$f" "checkout:$dir/$f" >/dev/null 2>&1; done
docker compose cp answers/cache.py "checkout:$dir/cache.py" >/dev/null 2>&1
docker compose exec -d -T checkout sh -c "cd $dir && echo \$\$ > origin.pid && exec python3 origin.py > origin.log 2>&1"
docker compose exec -d -T checkout sh -c "cd $dir && echo \$\$ > api.pid && exec python3 api.py > api.log 2>&1"

for _ in $(seq 1 50); do
  docker compose exec -T checkout python3 -c \
    "import urllib.request; urllib.request.urlopen('http://localhost:8231/stats', timeout=3); urllib.request.urlopen('http://localhost:8230/', timeout=3)" \
    >/dev/null 2>&1 && exit 0
  sleep 0.2
done
exit 3
