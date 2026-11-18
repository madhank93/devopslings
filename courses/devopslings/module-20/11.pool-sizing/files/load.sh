#!/usr/bin/env bash
# load.sh [SECONDS] — the on-sale: 80 app connections through pgbouncer to the
# boxoffice database, three bookings to every dashboard refresh. The app gives
# up on a booking after half a second and shows the customer an error. Prints
# one JSON line. Run from sandboxes/db-stack. DB names the pgbouncer database
# (default boxoffice).
set -euo pipefail
secs=${1:-15}
lesson=$(cd "$(dirname "$0")/.." && pwd)
docker compose cp "$lesson/files/book.sql" primary:/tmp/boxoffice-book.sql >/dev/null 2>&1
docker compose cp "$lesson/files/dashboard.sql" primary:/tmp/boxoffice-dashboard.sql >/dev/null 2>&1
timeout $(( secs + 60 )) docker compose exec -T -e PGPASSWORD=devopslings -e SECS="$secs" -e DB="${DB:-boxoffice}" primary bash -s <<'SH'
set -euo pipefail
log=/tmp/boxoffice-log
admin() { psql -h pgbouncer -U postgres -d pgbouncer -Atc "$1" 2>/dev/null; }
pool=$(admin 'SHOW DATABASES' | awk -F'|' -v db="$DB" '$1 == db { print $6 }' || true)
rm -rf "$log" && mkdir -p "$log"
out=$(cd "$log" && pgbench -n -h pgbouncer -U postgres -c 80 -j 8 -T "$SECS" -l \
  -f /tmp/boxoffice-book.sql@3 -f /tmp/boxoffice-dashboard.sql@1 "$DB" 2>&1) || true
# Close this pool's server connections, so they do not hold Postgres
# connections the next run needs.
admin "KILL $DB" >/dev/null || true
admin "RESUME $DB" >/dev/null || true
cat "$log"/pgbench_log.* 2>/dev/null | awk '$4 == 0 { print $3 }' | sort -n > "$log/book" || true
n=$(wc -l < "$log/book")
if [ "$n" = 0 ]; then
  echo '{"error": "no bookings completed"}'
  printf '%s\n' "$out" | tail -3 >&2
  exit 0
fi
p99=$(sed -n "$(( (n * 99 + 99) / 100 ))p" "$log/book")
late=$(awk '$1 > 500000' "$log/book" | wc -l)
printf '{"pool_size": %s, "bookings_per_s": %d, "booking_p99_ms": %d, "booking_errors": %d, "max_ms": %d}\n' \
  "${pool:-null}" $(( (n - late) / SECS )) $(( p99 / 1000 )) "$late" $(( $(tail -1 "$log/book") / 1000 ))
SH
