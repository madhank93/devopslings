#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Sweep the pool, then keep the size with the lowest booking p99 among those
# with no late bookings that sell within 5% of the best rate. Past that size
# the extra backends only share the CPU, and a booking holding a show's row is
# descheduled while the bookings behind it wait. Runs on the host with cwd =
# sandboxes/db-stack.
set -euo pipefail
set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-20/*.pool-sizing
lesson=$1
setpool() {
  docker compose exec -T pgbouncer sh -c "sed -i 's/^\(boxoffice *=.*pool_size=\)[0-9]*/\1$1/' /etc/pgbouncer/pgbouncer.ini"
  docker compose exec -T -e PGPASSWORD=devopslings primary psql -h pgbouncer -U postgres pgbouncer -c RELOAD >/dev/null
  sleep 1
}
mkdir -p answers
: > answers/pool-sizing.txt
for n in 4 8 12 16 24 48; do
  setpool "$n"
  bash "$lesson/files/load.sh" 8 >> answers/pool-sizing.txt
done
best=$(jq -s '(map(.bookings_per_s) | max) as $top
  | map(select(.booking_errors == 0 and .bookings_per_s >= 0.95 * $top))
  | (min_by(.booking_p99_ms) // {pool_size: 16}) | .pool_size' answers/pool-sizing.txt)
setpool "$best"
cat answers/pool-sizing.txt
echo "chose pool_size=$best"
