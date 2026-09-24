#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Three phases, none of which holds the table for more than a moment: add the
# new column, fill it in bounded batches, then drop the old one.
set -euo pipefail

cat > /work/app/migrate.sh <<'SH'
#!/usr/bin/env bash
# Migration 0117 — amount_cents (bigint, minor units) becomes amount
# (numeric, whole units), without taking the table away from the shop.
#
# The one-statement version rewrites three million rows under an ACCESS
# EXCLUSIVE lock, and every reader queues for the whole rewrite. Each
# statement below either touches the catalogue only, or touches rows a
# batch at a time and takes row locks that no reader waits on.
set -euo pipefail
export PGPASSWORD=devopslings
P() { psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 "$@"; }

# Expand. Nullable and with no default, so this is a catalogue change and
# returns immediately — a NOT NULL here would put the scan back.
P -c "ALTER TABLE payments ADD COLUMN IF NOT EXISTS amount numeric(14,2)" >/dev/null

# Backfill, bounded by primary key. The batch size is the knob: small enough
# that one statement is never the thing holding a lock anybody notices, large
# enough that the whole pass finishes in reasonable time. Re-running is safe —
# each batch only touches rows that are still null.
lo=$(P -c "SELECT min(id) FROM payments")
hi=$(P -c "SELECT max(id) FROM payments")
step=${BATCH:-100000}
while [ "$lo" -le "$hi" ]; do
  P -c "UPDATE payments SET amount = amount_cents / 100.0
         WHERE id >= $lo AND id < $lo + $step AND amount IS NULL" >/dev/null
  lo=$(( lo + step ))
done

# Contract. Dropping a column is a catalogue change too: the data is left in
# place and stops being addressable. It still takes the table lock, for the
# instant it needs rather than for the length of a rewrite.
P -c "ALTER TABLE payments DROP COLUMN amount_cents" >/dev/null
SH
chmod +x /work/app/migrate.sh

install -d /work/answers
cat > /work/answers/migration.md <<'MD'
# Migration 0117

# The plan was to run it at 3am. One line: what does a quiet period
# actually buy you here, and what does it not change?
what-quiet-period-buys: it changes how many people are queued behind the lock, not how long the table is held — the rewrite takes the same minutes at 3am and the outage is just as real to whatever is still running

# On this table, ALTER TABLE payments ADD COLUMN note text NOT NULL
# DEFAULT '' returns instantly, and ALTER COLUMN ... TYPE does not.
# One line: what is different about what Postgres has to do?
why-one-is-free: a constant default is stored once in the catalogue and handed to every existing row on read, while a type change has to compute and write a new value for every row, which means rewriting the whole table into a new file

# The lock the rewriting form takes on the table, as pg_locks names it.
the-lock: AccessExclusiveLock
MD

echo "migrate.sh rewritten as expand, batched backfill, contract"
