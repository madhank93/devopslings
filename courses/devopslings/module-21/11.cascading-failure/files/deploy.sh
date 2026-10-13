#!/usr/bin/env bash
# (Re)starts the four services with the hop settings in .env. reviews runs in
# the pricing container, the other three in the checkout container. Run from
# sandboxes/chaos-stack. Exits 3 naming the first service that did not come up;
# each one logs to /srv/cascading-failure/<name>.log in its container.
set -euo pipefail

lesson=$(cd "$(dirname "$0")/.." && pwd)
dir=/srv/cascading-failure
hops="GATEWAY_TO_PRODUCT GATEWAY_TO_ORDERS ORDERS_TO_PRODUCT PRODUCT_TO_REVIEWS"

env_args=()
for h in $hops; do
  for k in TIMEOUT POOL; do
    v=$(grep -E "^${h}_$k=" .env 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || true)
    env_args+=(-e "${h}_$k=$v")
  done
done

stop() {
  docker compose exec -T "$1" sh -c '
    p=$(cat '"$dir/$2"'.pid 2>/dev/null) || exit 0
    kill "$p" 2>/dev/null || exit 0
    while kill -0 "$p" 2>/dev/null; do sleep 0.1; done'
}
start() {
  docker compose exec -T "$1" mkdir -p "$dir"
  docker compose cp "$lesson/files/svc.py" "$1:$dir/svc.py" >/dev/null 2>&1
  docker compose exec -d -T "${env_args[@]}" "$1" \
    sh -c "cd $dir && echo \$\$ > $2.pid && exec python3 svc.py $2 > $2.log 2>&1"
}
ready() {
  for _ in $(seq 1 50); do
    docker compose exec -T "$1" python3 -c \
      "import urllib.request; urllib.request.urlopen('http://localhost:$3/health', timeout=1)" \
      >/dev/null 2>&1 && return 0
    sleep 0.2
  done
  echo "$2"
  exit 3
}

stop checkout gateway; stop checkout orders; stop checkout product; stop pricing reviews
start pricing reviews; start checkout product; start checkout orders; start checkout gateway
ready pricing reviews 8110; ready checkout product 8111
ready checkout orders 8112; ready checkout gateway 8113
