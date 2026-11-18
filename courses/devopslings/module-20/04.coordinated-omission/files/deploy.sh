#!/usr/bin/env bash
# (Re)starts search inside the checkout container. Run from sandboxes/chaos-stack.
# Exits 3 if it does not come up.
set -euo pipefail
lesson=$(cd "$(dirname "$0")/.." && pwd)
dir=/srv/coordinated-omission

docker compose exec -T checkout sh -c "
  mkdir -p $dir
  p=\$(cat $dir/pid 2>/dev/null) || exit 0
  kill \"\$p\" 2>/dev/null || exit 0
  while kill -0 \"\$p\" 2>/dev/null; do sleep 0.1; done"
docker compose cp "$lesson/files/svc.py" "checkout:$dir/svc.py" >/dev/null 2>&1
docker compose exec -d -T checkout sh -c "cd $dir && echo \$\$ > pid && exec python3 svc.py > svc.log 2>&1"

for _ in $(seq 1 50); do
  docker compose exec -T checkout python3 -c \
    "import urllib.request; urllib.request.urlopen('http://localhost:8200/', timeout=3)" \
    >/dev/null 2>&1 && exit 0
  sleep 0.2
done
exit 3
