#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Ask which indexes the workload actually reads through, drop the ones it never
# touches, and leave everything a query depends on alone.
set -euo pipefail
export PGPASSWORD=devopslings
P() { psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 "$@"; }

# Counters to zero, then the whole read workload, then look.
P -c "SELECT pg_stat_reset_single_table_counters(indexrelid)
        FROM pg_stat_user_indexes WHERE relname = 'orders'" >/dev/null

P >/dev/null <<'SQL'
SELECT id, status, total_cents FROM orders WHERE id = 4321987;
SELECT id, status, total_cents FROM orders WHERE reference = '5500000';
SELECT id, status, placed_at FROM orders
 WHERE customer_id = 12345 ORDER BY placed_at DESC LIMIT 20;
SELECT count(*) FROM orders
 WHERE placed_at >= date_trunc('day', now() - interval '30 days')
   AND placed_at <  date_trunc('day', now() - interval '29 days');
SQL

sleep 2

# lower(reference) and md5(reference): both were built for a caller that no
# longer exists, and no query in the workload can reach either one, because
# neither wraps the column in the expression the index is on.
P -c "DROP INDEX orders_lower_reference_idx" >/dev/null
P -c "DROP INDEX orders_reference_md5_idx" >/dev/null

install -d /work/answers
cat > /work/answers/index-cost.md <<'MD'
# Six indexes on orders

# The view that says how many times each index has actually been used
# since the counters were last reset.
usage-view: pg_stat_user_indexes

# What Postgres has to do on every inserted row for each index on the
# table — the per-index cost all six were charging.
write-cost: it inserts an index entry pointing at the new row and WAL-logs it, which can split a b-tree page, and a random key means that page is unlikely to be in shared buffers

# An idx_scan of 0 is not by itself proof that an index is dead. One
# line: what can make an index that is genuinely needed read zero?
why-zero-is-not-proof: the counter only covers the period since the statistics were last reset on this server, so a quarterly report's index, or one only read on the replica, or a unique index enforcing a constraint the planner never scans, all sit at zero while still being needed
MD

echo "dropped the two expression indexes nothing reads; four left, all of them in the workload"
