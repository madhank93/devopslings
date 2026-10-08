---
kind: lesson
title: "checkout is slow, and the cause is somewhere in the database"
description: |
  Checkout is slow and some requests time out. That is the whole ticket, every
  time — because the fault is drawn at random from five, each a different way
  a database stalls a request that did nothing wrong: a lock queue behind an
  idle session, a transaction with no session at all, a replica that stopped
  replaying, an index the query cannot use, and a planner that was told a lie.
  The drill is the order you ask the database questions in.
name: database-triage-drill
slug: database-triage-drill
createdAt: "2026-09-29"

sandbox:
  stack: db-stack
  service: primary

tasks:
  init_scenario:
    init: true
    timeout_seconds: 900
    run: |
      set -e
      export PGPASSWORD=devopslings
      P() { command psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 "$@"; }
      R() { command psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h replica "$@"; }

      install -d /work/app /work/answers /var/lib/drill
      rm -f /work/answers/triage.md /work/app/*.log

      # ---- clean slate -------------------------------------------------
      # db-stack persists between lessons and between runs of this one, so
      # every fault's residue is undone here whichever fault the last run drew.
      P -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
             WHERE datname = 'shop' AND pid <> pg_backend_pid()
               AND application_name IN ('finance-export', 'migration-0057', 'checkout')" >/dev/null
      for g in $(P -c "SELECT gid FROM pg_prepared_xacts WHERE database = 'shop'"); do
        P -c "ROLLBACK PREPARED '$g'" >/dev/null
      done
      R -c "ALTER SYSTEM RESET recovery_min_apply_delay" -c "SELECT pg_reload_conf()" >/dev/null
      R -c "SELECT pg_wal_replay_resume() WHERE pg_is_wal_replay_paused()" >/dev/null
      P -c "SET lock_timeout = '60s'" -c "ALTER TABLE orders DROP COLUMN IF EXISTS gift_note" >/dev/null

      # The seed's four indexes on orders and nothing else, so an index left by
      # an earlier run cannot hide the seeded one.
      for i in $(P -c "SELECT indexname FROM pg_indexes WHERE tablename = 'orders'
                         AND indexname NOT IN ('orders_pkey', 'orders_customer_id_idx',
                                               'orders_placed_at_idx', 'orders_reference_idx')"); do
        P -c "DROP INDEX IF EXISTS \"$i\"" >/dev/null
      done
      P -c "CREATE INDEX IF NOT EXISTS orders_reference_idx ON orders (reference)" >/dev/null
      P -c "ALTER TABLE orders ALTER COLUMN reference RESET (n_distinct)" \
        -c "ANALYZE orders (reference)" >/dev/null
      P -c "DELETE FROM orders WHERE reference LIKE 'CK-%'" >/dev/null

      P >/dev/null <<'SQL'
      CREATE TABLE IF NOT EXISTS stock (sku text PRIMARY KEY, qty integer NOT NULL);
      INSERT INTO stock SELECT 'SKU-' || g, 1000 FROM generate_series(1, 20) g
        ON CONFLICT (sku) DO UPDATE SET qty = 1000;

      -- The payment provider retries a checkout it did not hear back from, with
      -- the same key. The unique constraint is the only thing that stops the
      -- retry charging twice; nothing ever reads through its index.
      DROP TABLE IF EXISTS checkout_attempts;
      CREATE TABLE checkout_attempts (
          id              bigserial PRIMARY KEY,
          idempotency_key text NOT NULL,
          placed_at       timestamptz NOT NULL,
          CONSTRAINT checkout_attempts_idempotency_key_key UNIQUE (idempotency_key)
      );
      INSERT INTO checkout_attempts (idempotency_key, placed_at)
      SELECT 'idem-' || md5(g::text), now() - (g % 90) * interval '1 day'
        FROM generate_series(1, 1000000) g;
      ANALYZE checkout_attempts;
      SQL

      cat > /work/app/checkout.sh <<'SH'
      #!/usr/bin/env bash
      # Checkout for one unit of a SKU: take the stock, place the order, record
      # the attempt, then show the customer the order page.
      #
      # statement_timeout is the request budget. Past it the customer gets an
      # error page, so a statement that waits is a statement that fails.
      set -uo pipefail
      export PGPASSWORD=devopslings
      sku=${1:-SKU-7}
      ref="CK-$(date +%s%N)-$$"

      if ! err=$(psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 2>&1 >/dev/null <<SQL
      SET application_name = 'checkout';
      SET statement_timeout = '150ms';
      BEGIN;
      -- has this order been placed already?
      SELECT count(*) FROM orders WHERE reference = '$ref';
      UPDATE stock SET qty = qty - 1 WHERE sku = '$sku' AND qty > 0;
      INSERT INTO orders (customer_id, status, reference, total_cents, placed_at)
        VALUES (1, 'placed', '$ref', 4999, now());
      INSERT INTO checkout_attempts (idempotency_key, placed_at) VALUES ('idem-$ref', now());
      COMMIT;
      SQL
      ); then
        echo "checkout: FAILED $ref — $err"
        exit 1
      fi

      # The order page reads from the replica, as every read of orders does.
      for _ in $(seq 1 30); do
        status=$(psql -qtAX -U postgres -d shop -h replica \
                   -c "SELECT status FROM orders WHERE reference = '$ref'" 2>/dev/null || true)
        if [ -n "$status" ]; then
          echo "checkout: placed $ref — order page shows it $status"
          exit 0
        fi
        sleep 0.1
      done
      echo "checkout: placed $ref — order page TIMED OUT waiting for it"
      exit 1
      SH
      chmod +x /work/app/checkout.sh

      cat > /work/app/finance-export.sh <<'SH'
      #!/usr/bin/env bash
      # Finance export: read the day's totals, then write the CSV.
      set -euo pipefail
      export PGPASSWORD=devopslings
      {
        echo "BEGIN;"
        echo "SELECT count(*) FROM orders WHERE placed_at > now() - interval '1 day';"
        sleep 86400   # writing the CSV
        echo "COMMIT;"
      } | psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 \
            -c "SET application_name = 'finance-export'" -f -
      SH
      chmod +x /work/app/finance-export.sh

      cat > /work/app/migrate-0057.sh <<'SH'
      #!/usr/bin/env bash
      # migration-0057 — orders.gift_note, for the gift-wrap feature.
      set -euo pipefail
      export PGPASSWORD=devopslings
      exec psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 \
        -c "SET application_name = 'migration-0057'" \
        -c "ALTER TABLE orders ADD COLUMN IF NOT EXISTS gift_note text"
      SH
      chmod +x /work/app/migrate-0057.sh

      # Everything works at this point. Prove it before breaking one thing, so a
      # scenario that failed to come up cannot be mistaken for the seeded fault.
      ok=""
      for _ in 1 2 3 4 5; do
        if bash /work/app/checkout.sh >/dev/null 2>&1; then ok=yes; break; fi
        sleep 1
      done
      if [ -z "$ok" ]; then
        echo "the scenario did not come up healthy before the fault was seeded" >&2
        bash /work/app/checkout.sh >&2 || true
        exit 1
      fi

      # ---- seed one fault --------------------------------------------------
      faults="lock prepared replica index stats"
      n=$(od -An -N2 -tu2 < /dev/urandom | tr -d ' ')
      fault=$(echo "$faults" | cut -d' ' -f$(( n % 5 + 1 )))

      # The migration lands on every run but one, so its column says nothing
      # about which fault was drawn.
      [ "$fault" = lock ] || bash /work/app/migrate-0057.sh >/dev/null

      case "$fault" in
        prepared)
          # A two-phase commit whose coordinator never came back. The stock it
          # reserved belongs to an order that was never written, and the row
          # lock is held by no session at all.
          P >/dev/null <<'SQL'
      BEGIN;
      UPDATE stock SET qty = qty - 5 WHERE sku = 'SKU-7';
      PREPARE TRANSACTION 'checkout-7f3a91';
      SQL
          ;;
        index)
          # The reference index rebuilt for the support tool's case-insensitive
          # search. It is valid; checkout's lookup is not on lower(reference).
          P -c "DROP INDEX orders_reference_idx" \
            -c "CREATE INDEX orders_reference_lower_idx ON orders (lower(reference))" >/dev/null
          ;;
        stats)
          # A per-column override meant for status: the planner now believes
          # reference has one distinct value, so every lookup matches every row.
          P -c "ALTER TABLE orders ALTER COLUMN reference SET (n_distinct = 1)" \
            -c "ANALYZE orders (reference)" >/dev/null
          ;;
      esac

      # The export runs every time, and holds its read lock every time. It only
      # matters when something that needs the whole table is queued behind it.
      #
      # Helpers orphaned here are reaped by the postmaster (PID 1), which treats
      # any child exiting with a code other than 0 or 1 as a crashed backend and
      # restarts the server. The wrapper exits 0 however the helper ends.
      bg() { setsid bash -c "bash $1 >$2 2>&1; exit 0" </dev/null >/dev/null 2>&1 & }
      bg /work/app/finance-export.sh /work/app/finance-export.log
      for _ in $(seq 1 30); do
        s=$(P -c "SELECT state FROM pg_stat_activity WHERE application_name = 'finance-export'" || true)
        [ "$s" = "idle in transaction" ] && break
        sleep 1
      done

      if [ "$fault" = lock ]; then
        bg /work/app/migrate-0057.sh /work/app/migrate-0057.log
        for _ in $(seq 1 30); do
          w=$(P -c "SELECT wait_event_type FROM pg_stat_activity WHERE application_name = 'migration-0057'" || true)
          [ "$w" = "Lock" ] && break
          sleep 1
        done
      fi

      if [ "$fault" = replica ]; then
        R -c "SELECT pg_wal_replay_pause()" >/dev/null
      fi

      if bash /work/app/checkout.sh >/dev/null 2>&1; then
        echo "the seeded fault ($fault) did not stop checkout" >&2
        exit 1
      fi

      # The digest, not the name, and the app's own digest: the app is not
      # where any of the five lives, and changing it is how a symptom is hidden.
      {
        printf '%s' "$fault" | sha256sum | awk '{print $1}'
        sha256sum /work/app/checkout.sh | awk '{print $1}'
      } > /var/lib/drill/state
      chmod 600 /var/lib/drill/state

      echo "scenario ready"
      echo
      echo "  Checkout is slow and some requests time out. That's the ticket."
      echo
      echo "  the app:      /work/app/checkout.sh   (run it; it prints what the customer got)"
      echo "  your answer:  /work/answers/triage.md"
      echo
      echo "  primary: psql -h 127.0.0.1 -U postgres -d shop"
      echo "  replica: psql -h replica    -U postgres -d shop"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 600
    run: |
      export PGPASSWORD=devopslings
      P() { command psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 "$@"; }
      R() { command psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h replica "$@"; }
      app=/work/app/checkout.sh

      digest=$(sed -n 1p /var/lib/drill/state 2>/dev/null || true)
      app_sum=$(sed -n 2p /var/lib/drill/state 2>/dev/null || true)
      fault=""
      for cand in lock prepared replica index stats; do
        [ "$(printf '%s' "$cand" | sha256sum | awk '{print $1}')" = "$digest" ] && fault=$cand
      done
      if [ -z "$fault" ]; then
        echo "not yet: /var/lib/drill/state does not name a seeded fault. Start the"
        echo "         lesson again — the scenario has to seed one before it can be graded."
        exit 1
      fi

      if [ "$(sha256sum "$app" 2>/dev/null | awk '{print $1}')" != "$app_sum" ]; then
        echo "not yet: $app has changed. None of the five faults is in the app: a"
        echo "         longer timeout, a read sent to the primary or a lookup taken out"
        echo "         each make the ticket go quiet and leave the database as it was."
        echo "         Run 'devopslings reset database-triage-drill' to put it back."
        exit 1
      fi

      # ---- the symptom ----------------------------------------------------
      good=0
      last=""
      for _ in 1 2 3; do
        if out=$(bash "$app" 2>&1); then good=$((good + 1)); else last=$out; fi
      done
      if [ "$good" -lt 2 ]; then
        echo "not yet: $good of 3 checkouts completed. The last one said:"
        echo "         $last"
        echo "         Ask the database in order: is anything waiting on a lock, and on"
        echo "         whom (pg_stat_activity, pg_blocking_pids); is anything holding"
        echo "         locks with no session (pg_prepared_xacts); is the replica"
        echo "         replaying (pg_is_wal_replay_paused); and what plan does the"
        echo "         lookup get (EXPLAIN, \\d orders, pg_stats)."
        exit 1
      fi

      # ---- the repair is at the cause, not around it ----------------------
      if [ "$fault" = lock ]; then
        col=$(P -c "SELECT count(*) FROM information_schema.columns
                     WHERE table_name = 'orders' AND column_name = 'gift_note'" || true)
        if [ "${col:-0}" != "1" ]; then
          held=$(P -c "SELECT string_agg(a.application_name || ' (pid ' || a.pid || ', ' || a.state || ')', ', ')
                         FROM pg_stat_activity a
                        WHERE a.state = 'idle in transaction' AND EXISTS (
                              SELECT 1 FROM pg_locks l
                               WHERE l.pid = a.pid AND l.relation = 'orders'::regclass)" || true)
          echo "not yet: checkout completes, and orders has no gift_note column:"
          echo "         migration-0057 was stopped rather than let through. It was"
          echo "         the request at the front of the queue, not the one holding it."
          [ -n "$held" ] && echo "         Still holding a lock on orders: $held."
          echo "         The next piece of DDL on orders will queue exactly as it did."
          exit 1
        fi
      fi

      if [ "$fault" = prepared ]; then
        left=$(P -c "SELECT count(*) FROM pg_prepared_xacts WHERE database = 'shop'" || true)
        if [ "${left:-0}" != "0" ]; then
          echo "not yet: checkout completes and pg_prepared_xacts still has $left row(s)."
          exit 1
        fi
        qty=$(P -c "SELECT qty FROM stock WHERE sku = 'SKU-7'" || true)
        placed=$(P -c "SELECT count(*) FROM orders WHERE reference LIKE 'CK-%'" || true)
        want=$((1000 - ${placed:-0}))
        if [ "${qty:-x}" != "$want" ]; then
          echo "not yet: SKU-7 has $qty in stock, and 1000 less the $placed checkouts"
          echo "         placed is $want. The prepared transaction checkout-7f3a91 was"
          echo "         committed: its coordinator never wrote the order it was"
          echo "         reserving for, so its stock was reserved for nothing. It is"
          echo "         rolled back, not committed — put the difference back."
          exit 1
        fi
      fi

      if [ "$fault" = replica ]; then
        rec=$(R -c "SELECT pg_is_in_recovery()" || true)
        if [ "$rec" != "t" ]; then
          echo "not yet: the replica is no longer a standby (pg_is_in_recovery() is"
          echo "         '${rec:-no answer}'). Promoting it does not make it replay."
          exit 1
        fi
      fi

      # The lookup's plan, in a fresh session with no settings of the student's
      # own: an index on the column, and an estimate near the one row it finds.
      plan=$(P -c "EXPLAIN SELECT count(*) FROM orders WHERE reference = 'CK-grader'" 2>/dev/null || true)
      scan=$(printf '%s\n' "$plan" | grep -E 'Seq Scan|Index (Only )?Scan' | head -1 | sed 's/^[[:space:]>-]*//')
      est=$(printf '%s\n' "$scan" | sed -n 's/.*rows=\([0-9]*\).*/\1/p')
      if [ -z "$scan" ] || printf '%s' "$scan" | grep -q 'Seq Scan'; then
        echo "not yet: checkout passes, and its lookup on orders.reference still plans"
        echo "         as: ${scan:-no plan}."
        echo "         On ten million rows that is a request budget spent scanning."
        exit 1
      fi
      if [ "${est:-0}" -gt 1000 ]; then
        echo "not yet: the lookup on orders.reference uses an index, and the planner"
        echo "         expects $est rows from it where it finds at most one:"
        echo "         $scan"
        echo "         An index forced on a query the planner still misjudges is one"
        echo "         setting away from the scan coming back. Compare the estimate"
        echo "         with pg_stats for the column, and \\d+ orders for its options."
        exit 1
      fi

      # ---- the red herring ----------------------------------------------
      uq=$(P -c "SELECT count(*) FROM pg_constraint c JOIN pg_index i ON i.indexrelid = c.conindid
                  WHERE c.conrelid = 'checkout_attempts'::regclass AND c.contype = 'u'
                    AND i.indisvalid" 2>/dev/null || true)
      if [ "${uq:-0}" = "0" ]; then
        echo "not yet: checkout_attempts has no unique constraint on idempotency_key."
        echo "         Its index is never scanned, and it is not unused: every insert"
        echo "         checks it, and it is the only thing that stops a retried payment"
        echo "         being recorded twice. idx_scan counts reads, not uniqueness"
        echo "         checks. Put it back:"
        echo "         ALTER TABLE checkout_attempts ADD CONSTRAINT"
        echo "           checkout_attempts_idempotency_key_key UNIQUE (idempotency_key)"
        exit 1
      fi

      # ---- naming it ------------------------------------------------------
      ans=/work/answers/triage.md
      if [ ! -s "$ans" ]; then
        echo "not yet: $ans is missing or empty. Three lines: cause, evidence,"
        echo "         detection."
        exit 1
      fi
      low=$(tr 'A-Z' 'a-z' < "$ans")
      field() { printf '%s\n' "$low" | sed -n "s/^[[:space:]]*$1[[:space:]]*[:=][[:space:]]*//p" | awk 'NR==1'; }
      a_cause=$(field cause); a_ev=$(field evidence); a_det=$(field detection)

      case "$fault" in
        lock)
          what="a session idle in transaction held a read lock on orders, migration-0057 queued behind it for AccessExclusiveLock, and checkout queued behind the migration"
          c_re='\b(idle|migration|alter|ddl|queue|queued)\b'
          e_re='\b(pg_locks|pg_blocking_pids|pg_stat_activity)\b'
          e_say="pg_blocking_pids() on the waiting migration, or pg_locks with pg_stat_activity"
          d_re='\b(idle in transaction|xact_start|lock|locks|waiting|waits|blocked|blocking|wait_event)\b'
          d_say="sessions waiting on a lock, or the age of the oldest idle-in-transaction session" ;;
        prepared)
          what="an orphaned prepared transaction, checkout-7f3a91, held the row lock on SKU-7 with no session behind it"
          c_re='\b(prepared|2pc|two-phase|orphan|orphaned)\b'
          e_re='\b(pg_prepared_xacts|pg_locks)\b'
          e_say="pg_prepared_xacts, or a lock in pg_locks with no pid"
          d_re='\b(prepared|pg_prepared_xacts|2pc|two-phase|lock|locks|waiting|blocked)\b'
          d_say="the count or age of rows in pg_prepared_xacts, or lock waits" ;;
        replica)
          what="WAL replay on the replica was paused, so the order page never saw the order"
          c_re='\b(replay|paused|pause|replica|standby)\b'
          e_re='\b(pg_is_wal_replay_paused|pg_last_wal_replay_lsn|pg_last_wal_receive_lsn|pg_stat_replication|pg_stat_wal_receiver|pg_last_xact_replay_timestamp|replay_lsn|replay_lag)\b'
          e_say="pg_is_wal_replay_paused(), or the replay LSN against the receive LSN"
          d_re='\b(lag|replay|replay_lag|lsn|paused|replication)\b'
          d_say="replay lag, in seconds or bytes" ;;
        index)
          what="orders_reference_idx was replaced by an index on lower(reference), which the lookup on reference cannot use"
          c_re='\b(index|lower|expression|function)\b'
          e_re='\bexplain\b|\bpg_indexes\b|\bindexdef\b|\\d'
          e_say="EXPLAIN of the lookup, and \\d orders for what the index is on"
          d_re='\b(seq_scan|seq scan|seq_tup_read|sequential|mean_exec_time|pg_stat_statements|latency|p95|p99|duration|log_min_duration_statement)\b'
          d_say="the lookup's mean time in pg_stat_statements, or seq_scan on orders" ;;
        stats)
          what="orders.reference had n_distinct = 1 set on it, so the planner expected every row to match and scanned the table"
          c_re='\b(n_distinct|statistics|stats|estimate|estimated|misestimate|analyze|planner)\b'
          e_re='\bexplain\b|\bpg_stats\b|\bn_distinct\b|\battoptions\b|\\d\+'
          e_say="EXPLAIN's estimated rows against the actual, or pg_stats.n_distinct"
          d_re='\b(seq_scan|seq scan|seq_tup_read|sequential|mean_exec_time|pg_stat_statements|latency|p95|p99|duration|log_min_duration_statement|estimate)\b'
          d_say="the lookup's mean time in pg_stat_statements, or seq_scan on orders" ;;
      esac

      fail=0
      if [ -z "$a_cause" ] || ! printf '%s' "$a_cause" | grep -Eq "$c_re"; then
        fail=1
        echo "not yet: cause says '${a_cause:-nothing}', and checkout completes, so"
        echo "         something was repaired. What was seeded:"
        echo "         $what."
      fi
      if [ -z "$a_ev" ] || ! printf '%s' "$a_ev" | grep -Eq "$e_re"; then
        fail=1
        echo "not yet: evidence says '${a_ev:-nothing}'. For this fault the proof is"
        echo "         $e_say."
      fi
      if [ -z "$a_det" ] || ! printf '%s' "$a_det" | grep -Eq "$d_re"; then
        fail=1
        echo "not yet: detection says '${a_det:-nothing}'. Name a signal that would have"
        echo "         paged before customers did: $d_say."
      elif ! printf '%s' "$a_det" | grep -q '[0-9]'; then
        fail=1
        echo "not yet: detection names a signal and no threshold. Say at what number"
        echo "         it pages — 'lock waits > 5s', 'replay lag > 30s', with the number."
      fi
      [ "$fail" -eq 0 ] || exit 1

      echo "PASS — the seeded fault ($fault) was repaired at its cause, checkout is"
      echo "       unchanged and completes, the idempotency constraint is intact, and"
      echo "       triage.md names it."
---
