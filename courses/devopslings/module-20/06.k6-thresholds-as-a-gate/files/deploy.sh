#!/usr/bin/env bash
# deploy.sh BUILD — put a cart build on staging (checkout:8210). Run from
# sandboxes/chaos-stack. Exits 3 if it does not come up.
set -euo pipefail
lesson=$(cd "$(dirname "$0")/.." && pwd)
dir=/srv/k6-gate

docker compose exec -T checkout sh -c "
  mkdir -p $dir
  p=\$(cat $dir/pid 2>/dev/null) || exit 0
  kill \"\$p\" 2>/dev/null || exit 0
  while kill -0 \"\$p\" 2>/dev/null; do sleep 0.1; done"
docker compose cp "$lesson/files/cart.py" "checkout:$dir/cart.py" >/dev/null 2>&1
docker compose exec -d -T -e BUILD="$1" checkout sh -c "cd $dir && echo \$\$ > pid && exec python3 cart.py > cart.log 2>&1"

for _ in $(seq 1 50); do
  docker compose exec -T checkout python3 -c \
    "import urllib.request; urllib.request.urlopen('http://localhost:8210/', timeout=3)" \
    >/dev/null 2>&1 && exit 0
  sleep 0.2
done
exit 3
