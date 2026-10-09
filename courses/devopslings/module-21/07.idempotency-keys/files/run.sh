#!/usr/bin/env bash
# Deploys payments.py and client.py from this directory into chaos-stack, empties
# the ledger, and charges one batch of 30 orders through toxiproxy.
#
# Run it after every edit. It does not inject a fault: whatever toxics are on
# the `payments` proxy at the time are what the batch goes through.
set -euo pipefail

dir=${1:-$(cd "$(dirname "$0")" && pwd)}
pay=devopslings-chaos-stack-pricing-1
cli=devopslings-chaos-stack-checkout-1

# toxiproxy keeps runtime proxies in memory only, so a restarted toxiproxy has
# lost this one.
if ! curl -fsS http://127.0.0.1:8474/proxies/payments >/dev/null 2>&1; then
  curl -fsS -X POST http://127.0.0.1:8474/proxies -H 'Content-Type: application/json' \
    -d '{"name":"payments","listen":"0.0.0.0:21081","upstream":"pricing:8081","enabled":true}' >/dev/null
fi

# Stop the previous server and wait for it to go, so the health wait below
# cannot be answered by the old code.
docker exec "$pay" sh -c '
  mkdir -p /srv/payments
  if [ -f /srv/payments/pid ]; then
    pid=$(cat /srv/payments/pid); kill "$pid" 2>/dev/null || true
    i=0; while kill -0 "$pid" 2>/dev/null && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
  fi
  rm -f /srv/payments/pid /srv/payments/ledger.db /srv/payments/ledger.db-*'
docker cp -q "$dir/payments.py" "$pay:/srv/payments/payments.py"
docker exec -d "$pay" sh -c 'cd /srv/payments && echo $$ > pid && exec python3 payments.py > server.log 2>&1'

up=
for _ in $(seq 1 50); do
  if docker exec "$pay" python3 -c "import urllib.request; urllib.request.urlopen('http://localhost:8081/health', timeout=1)" >/dev/null 2>&1; then
    up=1; break
  fi
  sleep 0.2
done
if [ -z "$up" ]; then
  echo "payments.py did not start. Last lines of its log:"
  docker exec "$pay" tail -n 15 /srv/payments/server.log 2>/dev/null || true
  exit 3
fi

# Every (customer, amount) pair appears twice: two coffees are two charges, and
# a server that cannot tell a retry from a second purchase gets this wrong.
customers=(alice bob carol dan erin)
amounts=(9.99 12.50 20.00)
orders=$(for i in $(seq 1 30); do
  echo "$i ${customers[i % 5]} ${amounts[i % 3]}"
done)

docker exec "$cli" mkdir -p /srv/payments
docker cp -q "$dir/client.py" "$cli:/srv/payments/client.py"
printf '%s\n' "$orders" | docker exec -i "$cli" sh -c 'cat > /srv/payments/orders.txt'
docker exec -e PAYMENTS_URL=http://toxiproxy:21081 "$cli" \
  timeout 120 python3 /srv/payments/client.py /srv/payments/orders.txt || true

echo "---"
docker exec "$pay" python3 -c "
import sqlite3
rows = sqlite3.connect('/srv/payments/ledger.db').execute('SELECT id, customer, amount FROM charges ORDER BY id').fetchall()
print(f'ledger: {len(rows)} charges for 30 orders')"
