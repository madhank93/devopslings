#!/usr/bin/env bash
# Deploys consumer.py and orders.py from this directory into chaos-stack,
# refills the queue with 30 orders, and runs the consumer for at most 30s.
#
#   ./run.sh            # a healthy queue
#   ./run.sh --poison   # order 4 malformed, as at verify time
set -euo pipefail

dir=$(cd "$(dirname "$0")" && pwd)
ctr=devopslings-chaos-stack-checkout-1

docker exec "$ctr" mkdir -p /srv/queue
docker cp -q "$dir/orders.py" "$ctr:/srv/queue/orders.py"
docker cp -q "$dir/consumer.py" "$ctr:/srv/queue/consumer.py"
docker exec -w /srv/queue "$ctr" python3 orders.py seed ${1:+"$1"}

rc=0
docker exec -w /srv/queue "$ctr" timeout 30 python3 consumer.py || rc=$?
[ "$rc" -eq 124 ] && echo "(stopped: the consumer was still running after 30s)"

echo "---"
docker exec "$ctr" python3 -c "
import sqlite3
c = sqlite3.connect('/srv/queue/queue.db')
q = lambda s: c.execute(s).fetchone()[0]
print('pending    ', q(\"SELECT count(*) FROM messages WHERE status = 'pending'\"))
print('shipped    ', q('SELECT count(DISTINCT order_id) FROM shipped'), 'of 30 orders')
print('dead_letter', q('SELECT count(*) FROM dead_letter'))"
