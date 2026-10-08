---
kind: lesson
title: "the migration is forty minutes in and the whole table is frozen"
description: |
  A one-line `ALTER TABLE` that takes milliseconds has been running since
  09:20, and now every query against that table hangs behind it. The session
  actually holding things up is doing nothing at all — it has been idle for
  most of an hour with a transaction still open, and it never appears in a
  slow-query log because it is not running a query.
name: lock-contention
slug: lock-contention
createdAt: "2026-09-21"

sandbox:
  stack: db-stack
  service: primary

tasks:
  init_scenario:
    init: true
    timeout_seconds: 900
    run: |
      export PGPASSWORD=devopslings
      psql() { command psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 "$@"; }

      install -d /work/app /work/answers
      rm -f /work/answers/lock-contention.md /work/app/migrate.log /work/app/reporting-export.log

      # A rerun inherits whatever the last one left holding locks, and the DDL
      # below would queue behind them forever.
      psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
                WHERE datname = 'shop' AND pid <> pg_backend_pid()
                  AND application_name IN ('reporting-export', 'migration-0042', 'grader-blocker')" >/dev/null
      psql -c "SET lock_timeout = '60s'" \
           -c "ALTER TABLE orders DROP COLUMN IF EXISTS currency" >/dev/null

      cat > /work/app/reporting-export.sh <<'SH'
      #!/usr/bin/env bash
      # Nightly finance export: read the week's totals, write the CSV.
      set -euo pipefail
      export PGPASSWORD=devopslings

      {
        echo "BEGIN;"
        echo "SELECT count(*) FROM orders WHERE placed_at > now() - interval '7 days';"
        sleep 86400   # writing the CSV
        echo "COMMIT;"
      } | psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 \
            -c "SET application_name = 'reporting-export'" -f -
      SH
      chmod +x /work/app/reporting-export.sh

      cat > /work/app/migrate.sh <<'SH'
      #!/usr/bin/env bash
      # migration-0042 — orders needs a currency column. Everything placed so
      # far was in GBP, so the new column takes that as its default.
      set -euo pipefail
      export PGPASSWORD=devopslings

      exec psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 \
        -c "SET application_name = 'migration-0042'" \
        -c "ALTER TABLE orders ADD COLUMN IF NOT EXISTS currency text NOT NULL DEFAULT 'GBP'"
      SH
      chmod +x /work/app/migrate.sh

      cat > /work/answers/lock-contention.md <<'MD'
      # The migration that is not doing anything

      # The session holding the lock the migration is waiting for: the state
      # pg_stat_activity reports for it, spelled the way it prints it.
      blocker-state: ?

      # The lock mode the migration is waiting to be granted on orders, as
      # pg_locks names it.
      migration-wants: ?

      # A plain SELECT on orders hangs too — even though the session holding
      # the lock only ever read from the table. One line: why?
      why-selects-hang: ?
      MD

      # Wrapped so the orphan always exits 0: it is reparented to the postmaster,
      # which crash-restarts the server when an unknown child exits non-0/1.
      setsid bash -c "bash /work/app/reporting-export.sh >/work/app/reporting-export.log 2>&1; exit 0" </dev/null >/dev/null 2>&1 &
      for _ in $(seq 1 30); do
        s=$(psql -c "SELECT state FROM pg_stat_activity WHERE application_name = 'reporting-export'" || true)
        [ "$s" = "idle in transaction" ] && break
        sleep 1
      done

      setsid bash -c "bash /work/app/migrate.sh >/work/app/migrate.log 2>&1; exit 0" </dev/null >/dev/null 2>&1 &
      for _ in $(seq 1 30); do
        w=$(psql -c "SELECT wait_event_type FROM pg_stat_activity WHERE application_name = 'migration-0042'" || true)
        [ "$w" = "Lock" ] && break
        sleep 1
      done
      if [ "${w:-}" != "Lock" ]; then
        echo "scenario did not establish: migration-0042 is not waiting on a lock" >&2
        exit 1
      fi

      echo "scenario ready — migration-0042 is waiting, and so is everything behind it"
      echo
      echo "  the migration:  /work/app/migrate.sh   (already running, blocked)"
      echo "  the export:     /work/app/reporting-export.sh"
      echo "  your answer:    /work/answers/lock-contention.md"
      echo
      echo "Try reading the table it is altering — then press Ctrl-C:"
      echo
      echo "  export PGPASSWORD=devopslings"
      echo "  psql -h 127.0.0.1 -U postgres -d shop -c 'SELECT count(*) FROM orders'"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 600
    run: |
      export PGPASSWORD=devopslings
      psql() { command psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 "$@"; }
      ans=/work/answers/lock-contention.md
      mig=/work/app/migrate.sh

      if [ ! -s "$ans" ]; then
        echo "not yet: $ans is missing or empty"
        exit 1
      fi
      if grep -q ': *?$' "$ans" 2>/dev/null; then
        echo "not yet: $ans still has unanswered '?' fields"
        exit 1
      fi
      if [ ! -s "$mig" ]; then
        echo "not yet: $mig is missing or empty. The migration still has to run."
        echo "Run 'devopslings reset lock-contention' to put the scenario back."
        exit 1
      fi

      field() {
        grep -E "^$1:" "$ans" 2>/dev/null | head -1 | sed "s/^$1: *//" | tr -d '\r' || true
      }

      # The catalogue read takes no lock on orders itself, so this answers even
      # while an ALTER is still queued on the table.
      has_col=$(psql -c "SELECT count(*) FROM information_schema.columns
                          WHERE table_name = 'orders' AND column_name = 'currency'" || true)
      if [ "${has_col:-0}" != "1" ]; then
        echo "not yet: orders still has no currency column, so the migration has not"
        echo "landed. It is not stuck on the ten million rows — adding a column with a"
        echo "default has been a catalogue-only change since Postgres 11. It is waiting"
        echo "for a lock, and something that is not running a query is holding it."
        exit 1
      fi

      idle=$(psql -c "SELECT count(*) FROM pg_stat_activity
                       WHERE datname = 'shop' AND state = 'idle in transaction'" || true)
      if [ "${idle:-0}" != "0" ]; then
        who=$(psql -c "SELECT application_name || ' (pid ' || pid || ', open ' ||
                              date_trunc('second', now() - xact_start) || ')'
                         FROM pg_stat_activity
                        WHERE datname = 'shop' AND state = 'idle in transaction'
                        LIMIT 1" || true)
        echo "not yet: a session is still sitting in an open transaction: ${who}."
        echo "The migration got through, but that session goes on holding its locks"
        echo "until it commits — and the next piece of DDL queues behind it exactly"
        echo "the way this one did."
        exit 1
      fi

      got_state=$(field blocker-state | tr 'A-Z' 'a-z')
      case "$got_state" in
        *"idle in transaction"*) ;;
        *idle*)
          echo "not yet: 'blocker-state:' says '${got_state}'. A session that is plain"
          echo "'idle' has no transaction open and holds nothing — it is the other"
          echo "state, the one pg_stat_activity prints for a connection that ran BEGIN"
          echo "and then stopped talking."
          exit 1
          ;;
        *)
          echo "not yet: 'blocker-state:' says '${got_state:-nothing}', which is not a"
          echo "state pg_stat_activity prints. Read the state column of the session in"
          echo "pg_blocking_pids() for the migration, and copy it as it is spelled."
          exit 1
          ;;
      esac

      got_mode=$(field migration-wants | tr -d ' ' | tr 'A-Z' 'a-z')
      case "$got_mode" in
        *accessexclusive*) ;;
        *exclusive*)
          echo "not yet: 'migration-wants:' says '$(field migration-wants)'. ExclusiveLock"
          echo "and AccessExclusiveLock are two different modes, and only one of them"
          echo "conflicts with a plain SELECT. Read the mode of the ungranted row in"
          echo "pg_locks for the orders relation."
          exit 1
          ;;
        *)
          echo "not yet: 'migration-wants:' says '$(field migration-wants)'. pg_locks has"
          echo "one row per lock with a 'granted' column — the migration's row is the"
          echo "one where granted is false. Its 'mode' is the answer."
          exit 1
          ;;
      esac

      why=$(field why-selects-hang | tr 'A-Z' 'a-z')
      if ! printf '%s' "$why" | grep -Eq '\b(queue|queued|queues|queuing|queueing|fifo|in order|ahead|behind|first)\b'; then
        echo "not yet: 'why-selects-hang:' does not explain the ordering. The export"
        echo "holds AccessShareLock, which does not conflict with another reader at"
        echo "all — two SELECTs never wait for each other. Something changed when the"
        echo "migration arrived. Where does a new lock request go when one ahead of it"
        echo "cannot be granted?"
        exit 1
      fi
      if ! printf '%s' "$why" | grep -Eq '\b(alter|migration|ddl|exclusive|accessexclusivelock)\b'; then
        echo "not yet: 'why-selects-hang:' names an ordering but not what the SELECT is"
        echo "ordered behind. Say which waiting request it is stuck behind, and why"
        echo "that one conflicts with a read when the export's lock did not."
        exit 1
      fi

      # The durable half: a migration with no bound on its lock wait takes the
      # whole table down with it whenever anything is holding a lock. Prove the
      # bound exists by putting a lock in its way.
      cleanup() {
        psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
                  WHERE datname = 'shop' AND application_name = 'grader-blocker'" >/dev/null 2>&1 || true
      }
      trap cleanup EXIT

      cat > /tmp/grader-blocker.sh <<'B'
      { echo "BEGIN;"; echo "SELECT 1 FROM orders WHERE id = 1;"; sleep 120; } |
        psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 \
          -c "SET application_name = 'grader-blocker'" -f -
      B
      # Wrapped so the orphan always exits 0: it is reparented to the postmaster,
      # which crash-restarts the server when an unknown child exits non-0/1.
      setsid bash -c "bash /tmp/grader-blocker.sh >/dev/null 2>&1; exit 0" </dev/null >/dev/null 2>&1 &

      held=no
      for _ in $(seq 1 30); do
        s=$(psql -c "SELECT state FROM pg_stat_activity WHERE application_name = 'grader-blocker'" || true)
        if [ "$s" = "idle in transaction" ]; then held=yes; break; fi
        sleep 1
      done
      if [ "$held" != "yes" ]; then
        echo "not yet: the grader could not open a transaction of its own to test the"
        echo "migration against. Run 'devopslings reset lock-contention' and try again."
        exit 1
      fi

      started=$(date +%s)
      rc=0
      timeout 30 bash "$mig" >/tmp/grader-migrate.log 2>&1 || rc=$?
      waited=$(( $(date +%s) - started ))

      if [ "$rc" = "124" ]; then
        echo "not yet: with one read lock held on orders, $mig was still waiting when"
        echo "the grader stopped it at 30s. Either nothing bounds its lock wait, or the"
        echo "bound is longer than that — and either way it spends the wait queued for"
        echo "AccessExclusiveLock with every reader piling up behind it. Bound it in"
        echo "seconds, not minutes: see lock_timeout."
        exit 1
      fi
      if [ "$rc" = "0" ]; then
        echo "not yet: $mig succeeded in ${waited}s while the grader held a read lock on"
        echo "orders, so it never queued for anything. It still has to run its ALTER"
        echo "against the table — skipping the work is not the same as bounding the"
        echo "wait for it."
        exit 1
      fi

      echo "PASS — the migration landed, the transaction that was holding it is closed,"
      echo "and $mig now gives up after ${waited}s against a held lock instead of taking"
      echo "the table down with it."
---
