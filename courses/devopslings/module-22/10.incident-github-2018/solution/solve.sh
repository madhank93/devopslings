#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# An order is identified by (id, reference): the same id on both sides can be
# two different orders. The reconstruction compares those pairs. The failback
# fences pg2, copies the orders only pg2 has onto pg1 under new ids, moves the
# app back, and rebuilds pg2 as pg1's standby.
set -euo pipefail
work=$(mktemp -d)
for h in pg1 pg2; do
  psql -h "$h" -qtAXc "select id || '|' || reference from orders" | sort > "$work/$h"
done
comm -23 "$work/pg1" "$work/pg2" > "$work/east"
comm -13 "$work/pg1" "$work/pg2" > "$work/west"
cut -d'|' -f1 "$work/east" | sort > "$work/east-ids"
cut -d'|' -f1 "$work/west" | sort > "$work/west-ids"
cat > /ha/answers/github-2018.txt <<TXT
only_on_pg1: $(wc -l < "$work/east" | tr -d ' ')
only_on_pg2: $(wc -l < "$work/west" | tr -d ' ')
same_id_both: $(comm -12 "$work/east-ids" "$work/west-ids" | wc -l | tr -d ' ')
TXT
rm -rf "$work"

cat > /ha/failback.sh <<'SH'
#!/bin/bash
set -euo pipefail
# 1. Fence pg2: from here on it accepts no write that could be left behind.
psql -h pg2 -qtAX -c "ALTER SYSTEM SET default_transaction_read_only = on" -c "SELECT pg_reload_conf()"
psql -h pg2 -qtAX -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE backend_type = 'client backend' AND pid <> pg_backend_pid()" >/dev/null

# 2. Copy every order pg1 does not have, matched on id AND reference, and let
#    pg1 give each one a new id: the old one may already belong to another order.
psql -h pg1 -qtAX -v ON_ERROR_STOP=1 -c "CREATE TABLE IF NOT EXISTS failback_import (id bigint, reference text, placed_at timestamptz)" -c "TRUNCATE failback_import"
psql -h pg2 -qtAX -v ON_ERROR_STOP=1 -c "\copy (SELECT id, reference, placed_at FROM orders) TO STDOUT" \
  | psql -h pg1 -qtAX -v ON_ERROR_STOP=1 -c "\copy failback_import FROM STDIN"
psql -h pg1 -qtAX -v ON_ERROR_STOP=1 \
  -c "INSERT INTO orders (reference, placed_at)
      SELECT i.reference, i.placed_at FROM failback_import i
      WHERE NOT EXISTS (SELECT 1 FROM orders o WHERE o.id = i.id AND o.reference = i.reference)
      ORDER BY i.id" \
  -c "DROP TABLE failback_import"

# 3. The app goes home.
sed -i 's/host=pg2/host=pg1/' /ha/app.env

# 4. pg2's history since its promotion is now on pg1; rebuild it as a standby.
mkdir -p /ha/pg2 && touch /ha/pg2/reclone
docker restart devopslings-ha-pg2 >/dev/null
for _ in $(seq 120); do
  [ "$(psql -h pg1 -qtAXc "select count(*) from pg_stat_replication where application_name = 'pg2' and state = 'streaming'")" = 1 ] && exit 0
  sleep 1
done
echo "pg2 did not start streaming from pg1" >&2
exit 1
SH
chmod +x /ha/failback.sh
