#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Two separate things: close the transaction that is holding the lock so the
# queued migration can proceed, and give the migration a bound on how long it
# is willing to queue next time.
set -euo pipefail

export PGPASSWORD=devopslings
psql() { command psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 "$@"; }

# The export is idle in transaction: no query to cancel, only a session to end.
psql -c "SELECT pg_terminate_backend(pid)
           FROM pg_stat_activity
          WHERE datname = 'shop'
            AND state = 'idle in transaction'" >/dev/null

# The migration was already queued; it takes its lock as soon as the export
# lets go.
for _ in $(seq 1 30); do
  n=$(psql -c "SELECT count(*) FROM information_schema.columns
                WHERE table_name = 'orders' AND column_name = 'currency'")
  [ "$n" = "1" ] && break
  sleep 1
done
if [ "${n:-0}" != "1" ]; then
  # Nothing was left queued — run it directly.
  bash /work/app/migrate.sh
fi

cat > /work/app/migrate.sh <<'SH'
#!/usr/bin/env bash
# migration-0042 — orders needs a currency column. Everything placed so far
# was in GBP, so the new column takes that as its default.
#
# lock_timeout bounds the queueing, not the ALTER: every reader that arrives
# while this waits for AccessExclusiveLock waits behind it, so failing after
# three seconds costs a retry and holding on costs the table.
set -euo pipefail
export PGPASSWORD=devopslings

exec psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 \
  -c "SET application_name = 'migration-0042'" \
  -c "SET lock_timeout = '3s'" \
  -c "ALTER TABLE orders ADD COLUMN IF NOT EXISTS currency text NOT NULL DEFAULT 'GBP'"
SH
chmod +x /work/app/migrate.sh

install -d /work/answers
cat > /work/answers/lock-contention.md <<'MD'
# The migration that is not doing anything

# The session holding the lock the migration is waiting for: the state
# pg_stat_activity reports for it, spelled the way it prints it.
blocker-state: idle in transaction

# The lock mode the migration is waiting to be granted on orders, as
# pg_locks names it.
migration-wants: AccessExclusiveLock

# A plain SELECT on orders hangs too — even though the session holding
# the lock only ever read. One line: why?
why-selects-hang: lock requests are granted in order, so the SELECT queues behind the ALTER's ungranted AccessExclusiveLock rather than beside the export's read lock
MD

echo "export terminated, migration landed, migrate.sh now bounds its lock wait"
