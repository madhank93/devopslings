#!/usr/bin/env bash
# (Re)starts api inside the checkout container with the settings in .env.
# Run from sandboxes/chaos-stack. Exits 3 if api does not come up; its log is
# then at /srv/load-shedding/api.log in that container.
set -euo pipefail

lesson=$(cd "$(dirname "$0")/.." && pwd)
env_val() { grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || true; }

docker compose exec -T checkout sh -c '
  mkdir -p /srv/load-shedding
  p=$(cat /srv/load-shedding/pid 2>/dev/null) || exit 0
  kill "$p" 2>/dev/null || exit 0
  while kill -0 "$p" 2>/dev/null; do sleep 0.1; done'
docker compose cp "$lesson/files/api.py" checkout:/srv/load-shedding/api.py >/dev/null
docker compose exec -d -T \
  -e API_WORKERS="$(env_val API_WORKERS)" \
  -e QUEUE_TIMEOUT_MS="$(env_val QUEUE_TIMEOUT_MS)" \
  -e SHED_ALL_AT="$(env_val SHED_ALL_AT)" \
  -e SHED_LOW_AT="$(env_val SHED_LOW_AT)" \
  checkout sh -c 'cd /srv/load-shedding && echo $$ > pid && exec python3 api.py > api.log 2>&1'

for _ in $(seq 1 50); do
  docker compose exec -T checkout python3 -c \
    "import urllib.request; urllib.request.urlopen('http://localhost:8100/health', timeout=1)" \
    >/dev/null 2>&1 && exit 0
  sleep 0.2
done
exit 3
