#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The fault is drawn at random, so this is the ladder the lesson teaches, walked
# in order and stopped at the first rung that answers: waits, then locks with no
# session, then the replica, then the plan.
set -euo pipefail
export PGPASSWORD=devopslings
P() { command psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 "$@"; }
R() { command psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h replica "$@"; }

cause="" evidence="" detection=""

# ---- is anything queued on a lock, and behind whom? ----------------------
# An idle session is only the fault when something is waiting on it, and the
# one to end is the holder, not the waiter at the front of the queue.
blockers=$(P -c "SELECT DISTINCT unnest(pg_blocking_pids(pid)) FROM pg_stat_activity
                  WHERE wait_event_type = 'Lock' AND datname = 'shop'")
if [ -n "$blockers" ]; then
  for b in $blockers; do P -c "SELECT pg_terminate_backend($b)" >/dev/null; done
  for _ in $(seq 1 30); do
    [ "$(P -c "SELECT count(*) FROM information_schema.columns
                WHERE table_name = 'orders' AND column_name = 'gift_note'")" = 1 ] && break
    sleep 1
  done
  cause="finance-export sat idle in transaction holding a read lock on orders; migration-0057 queued behind it and checkout queued behind the migration"
  evidence="pg_blocking_pids() of the waiting migration named the idle session in pg_stat_activity"
  detection="page when any session has waited on a lock for more than 5 seconds, or is idle in transaction for more than 60 seconds"
fi

# ---- locks held by no session ------------------------------------------
if [ -z "$cause" ] && [ "$(P -c "SELECT count(*) FROM pg_prepared_xacts WHERE database = 'shop'")" != 0 ]; then
  # Its coordinator never wrote the order it reserved stock for: roll back.
  for g in $(P -c "SELECT gid FROM pg_prepared_xacts WHERE database = 'shop'"); do
    P -c "ROLLBACK PREPARED '$g'" >/dev/null
  done
  cause="an orphaned prepared transaction held the row lock on SKU-7 with no session behind it"
  evidence="pg_prepared_xacts, and a lock in pg_locks with no pid"
  detection="page when any row in pg_prepared_xacts is older than 60 seconds"
fi

# ---- is the replica replaying? -----------------------------------------
if [ -z "$cause" ] && [ "$(R -c "SELECT pg_is_wal_replay_paused()")" = t ]; then
  R -c "SELECT pg_wal_replay_resume()" >/dev/null
  cause="WAL replay on the replica was paused, so the order page never saw the new order"
  evidence="pg_is_wal_replay_paused() returned true while pg_last_wal_receive_lsn kept moving"
  detection="page when replay lag exceeds 30 seconds"
fi

# ---- what plan does the lookup get? ------------------------------------
if [ -z "$cause" ] && P -c "EXPLAIN SELECT count(*) FROM orders WHERE reference = 'x'" | grep -q 'Seq Scan'; then
  if ! P -c "SELECT indexdef FROM pg_indexes WHERE tablename = 'orders'" | grep -q 'btree (reference)'; then
    P -c "CREATE INDEX CONCURRENTLY orders_reference_idx ON orders (reference)" >/dev/null
    cause="the only index on reference is on lower(reference), which a lookup on reference cannot use"
    evidence="EXPLAIN showed a seq scan, and \\d orders showed the index was on lower(reference)"
    detection="page when the lookup's mean_exec_time in pg_stat_statements exceeds 50 ms"
  else
    P -c "ALTER TABLE orders ALTER COLUMN reference RESET (n_distinct)" -c "ANALYZE orders (reference)" >/dev/null
    cause="n_distinct = 1 on orders.reference made the planner estimate every row matches"
    evidence="EXPLAIN estimated ten million rows for one; pg_stats showed n_distinct 1"
    detection="page when the lookup's mean_exec_time in pg_stat_statements exceeds 50 ms"
  fi
fi

if [ -z "$cause" ]; then
  echo "no rung of the ladder answered, and the scenario seeds a fault on every run"
  exit 1
fi

install -d /work/answers
printf 'cause: %s\nevidence: %s\ndetection: %s\n' "$cause" "$evidence" "$detection" > /work/answers/triage.md
bash /work/app/checkout.sh
