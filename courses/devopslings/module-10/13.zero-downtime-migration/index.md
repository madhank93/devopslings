---
kind: lesson
title: "the migration is ready and nobody will say when it can run"
description: |
  `payments.amount_cents` has to become a numeric column. The migration is one
  statement, it has been reviewed, and it has been waiting a fortnight for a
  window — because the last one like it took the table away for minutes in the
  middle of the afternoon. The window is not the answer, and the statement
  everybody is afraid of is not the one that hurts.
name: zero-downtime-migration
slug: zero-downtime-migration
createdAt: "2026-09-24"
timingSensitive: true

sandbox:
  stack: db-stack
  service: primary

tasks:
  init_scenario:
    init: true
    timeout_seconds: 900
    run: |
      export PGPASSWORD=devopslings
      P() { command psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 "$@"; }

      install -d /work/app /work/answers
      rm -f /work/answers/migration.md

      P >/dev/null <<'SQL'
      DROP TABLE IF EXISTS payments;
      CREATE TABLE payments (
          id           bigserial PRIMARY KEY,
          order_ref    text NOT NULL,
          amount_cents bigint NOT NULL,
          captured_at  timestamptz NOT NULL
      );
      INSERT INTO payments (order_ref, amount_cents, captured_at)
      SELECT 'PAY-' || g, 100 + (g % 900000), now() - (g % 500) * interval '1 hour'
      FROM generate_series(1, 3000000) g;
      SQL
      P -c "VACUUM (ANALYZE) payments" >/dev/null

      cat > /work/app/migrate.sh <<'SH'
      #!/usr/bin/env bash
      # Migration 0117 — amount_cents (bigint, minor units) becomes
      # amount (numeric, whole units), because six services currently divide
      # by a hundred in six slightly different places.
      #
      # Reviewed and approved. Waiting on a maintenance window.
      set -euo pipefail
      export PGPASSWORD=devopslings
      P() { psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 "$@"; }

      P -c "ALTER TABLE payments
              ALTER COLUMN amount_cents TYPE numeric(14,2) USING amount_cents / 100.0"
      P -c "ALTER TABLE payments RENAME COLUMN amount_cents TO amount"
      SH
      chmod +x /work/app/migrate.sh

      cat > /work/answers/migration.md <<'MD'
      # Migration 0117

      # The plan was to run it at 3am. One line: what does a quiet period
      # actually buy you here, and what does it not change?
      what-quiet-period-buys: ?

      # On this table, ALTER TABLE payments ADD COLUMN note text NOT NULL
      # DEFAULT '' returns instantly, and ALTER COLUMN ... TYPE does not.
      # One line: what is different about what Postgres has to do?
      why-one-is-free: ?

      # The lock the rewriting form takes on the table, as pg_locks names it.
      the-lock: ?
      MD

      echo "scenario ready"
      echo
      echo "  payments:     $(P -c 'SELECT count(*) FROM payments') rows, $(P -c "SELECT pg_size_pretty(pg_total_relation_size('payments'))")"
      echo "  the change:   /work/app/migrate.sh"
      echo "  your answer:  /work/answers/migration.md"
      echo
      echo "  psql -h 127.0.0.1 -U postgres -d shop"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 900
    run: |
      export PGPASSWORD=devopslings
      P() { command psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 "$@"; }
      ans=/work/answers/migration.md
      app=/work/app/migrate.sh

      if [ ! -s "$ans" ]; then
        echo "not yet: $ans is missing or empty"
        exit 1
      fi
      if grep -q ': *?$' "$ans" 2>/dev/null; then
        echo "not yet: $ans still has unanswered '?' fields"
        exit 1
      fi
      if [ ! -s "$app" ]; then
        echo "not yet: $app is missing or empty. The migration still has to run."
        echo "Run 'devopslings reset zero-downtime-migration' to put the scenario back."
        exit 1
      fi

      field() {
        grep -E "^$1:" "$ans" 2>/dev/null | head -1 | sed "s/^$1: *//" | tr -d '\r' || true
      }

      # Back to the un-migrated table first. This check runs the migration, so it
      # cannot start from whatever its own last run left behind — and a student
      # who has already run migrate.sh by hand gets a clean table to be graded
      # on rather than a half-finished one.
      P >/dev/null <<'SQL'
      DROP TABLE IF EXISTS payments;
      CREATE TABLE payments (
          id           bigserial PRIMARY KEY,
          order_ref    text NOT NULL,
          amount_cents bigint NOT NULL,
          captured_at  timestamptz NOT NULL
      );
      INSERT INTO payments (order_ref, amount_cents, captured_at)
      SELECT 'PAY-' || g, 100 + (g % 900000), now() - (g % 500) * interval '1 hour'
      FROM generate_series(1, 3000000) g;
      SQL
      P -c "VACUUM (ANALYZE) payments" >/dev/null
      rows_before=$(P -c "SELECT count(*) FROM payments")
      cents=$(P -c "SELECT sum(amount_cents) FROM payments")

      # The shop, still open. Each round reads one row by primary key and
      # writes another, and each gives up after a second. Neither names a column
      # the migration touches: a table lock refuses the read, and a backfill
      # that holds its row locks for longer than a batch refuses the write.
      cat > /tmp/grader-reader.sh <<'SH'
      #!/usr/bin/env bash
      export PGPASSWORD=devopslings
      q() { psql -qtAX -U postgres -d shop -h 127.0.0.1 -c "SET lock_timeout = '1s'" -c "$1"; }
      refused=0; ok=0; wrefused=0; wok=0
      while [ ! -f /tmp/grader-reader.stop ]; do
        if q "SELECT id, order_ref FROM payments WHERE id = 1234567" \
             >/dev/null 2>>/tmp/grader-reader.err; then
          ok=$(( ok + 1 ))
        else
          refused=$(( refused + 1 ))
        fi
        id=$(( (RANDOM * 32768 + RANDOM) % 3000000 + 1 ))
        if q "UPDATE payments SET order_ref = order_ref WHERE id = $id" \
             >/dev/null 2>>/tmp/grader-writer.err; then
          wok=$(( wok + 1 ))
        else
          wrefused=$(( wrefused + 1 ))
        fi
        sleep 0.2
      done
      echo "$ok $refused $wok $wrefused" > /tmp/grader-reader.out
      SH
      rm -f /tmp/grader-reader.stop /tmp/grader-reader.out
      : > /tmp/grader-reader.err
      : > /tmp/grader-writer.err
      # Wrapped so the orphan always exits 0: it is reparented to the postmaster,
      # which crash-restarts the server when an unknown child exits non-0/1.
      setsid bash -c "bash /tmp/grader-reader.sh; exit 0" </dev/null >/dev/null 2>&1 &
      sleep 1

      rc=0
      timeout 600 bash "$app" >/tmp/grader-migrate.log 2>&1 || rc=$?

      touch /tmp/grader-reader.stop
      for _ in $(seq 1 20); do [ -f /tmp/grader-reader.out ] && break; sleep 1; done
      read -r served refused wserved wrefused < /tmp/grader-reader.out 2>/dev/null ||
        { served=0; refused=0; wserved=0; wrefused=0; }

      if [ "$rc" != "0" ]; then
        echo "not yet: $app exited $rc:"
        tail -5 /tmp/grader-migrate.log | sed 's/^/    /'
        exit 1
      fi

      # --- the column has to have actually landed -----------------------------
      typ=$(P -c "SELECT data_type FROM information_schema.columns
                   WHERE table_name = 'payments' AND column_name = 'amount'")
      if [ -z "$typ" ]; then
        echo "not yet: payments has no 'amount' column. The migration's job is to leave one"
        echo "there, in whole currency units."
        exit 1
      fi
      if [ "$typ" != "numeric" ]; then
        echo "not yet: payments.amount is $typ, not numeric."
        exit 1
      fi
      if [ -n "$(P -c "SELECT 1 FROM information_schema.columns
                        WHERE table_name = 'payments' AND column_name = 'amount_cents'")" ]; then
        echo "not yet: amount_cents is still on the table beside amount. Expanding is half"
        echo "the job — until the old column is gone, every service still has two places to"
        echo "read the figure from and one of them is wrong."
        exit 1
      fi

      rows_after=$(P -c "SELECT count(*) FROM payments")
      if [ "${rows_after:-0}" != "${rows_before:-x}" ]; then
        echo "not yet: payments had ${rows_before} rows before the migration and has"
        echo "${rows_after} now."
        exit 1
      fi
      nulls=$(P -c "SELECT count(*) FROM payments WHERE amount IS NULL")
      if [ "${nulls:-1}" != "0" ]; then
        echo "not yet: ${nulls} rows have a null amount. A backfill that stops early leaves"
        echo "exactly this: a column that exists, reads fine on the rows anybody spot-checked,"
        echo "and is empty further down the table."
        exit 1
      fi
      ok_sum=$(P -c "SELECT sum(amount) = ${cents}::numeric / 100 FROM payments")
      if [ "$ok_sum" != "t" ]; then
        echo "not yet: the amounts do not add up. payments summed to ${cents} cents before"
        echo "the migration and sums to $(P -c 'SELECT sum(amount) FROM payments') now, which"
        echo "should be that divided by a hundred."
        exit 1
      fi

      # --- and the shop had to stay open while it ran -------------------------
      if [ "${refused:-0}" -gt 0 ]; then
        echo "not yet: the migration finished, and ${refused} of the $(( served + refused )) reads that"
        echo "arrived while it ran were refused:"
        echo
        { sort -u /tmp/grader-reader.err 2>/dev/null || true; } | head -2 | sed 's/^/    /'
        echo
        echo "Those reads name no column the migration touches, so nothing about them is"
        echo "ambiguous — they were waiting for the table itself. Find which statement holds"
        echo "the table, and for how long, and get the same result without any single"
        echo "statement holding it that long."
        exit 1
      fi
      if [ "${wrefused:-0}" -gt 0 ]; then
        echo "not yet: every read was served, and ${wrefused} of the $(( wserved + wrefused )) row"
        echo "updates that arrived while the migration ran were refused:"
        echo
        { grep '^ERROR' /tmp/grader-writer.err 2>/dev/null || true; } | sort -u | head -2 | sed 's/^/    /'
        echo
        echo "A write waits when the row it wants is locked by a transaction that has not"
        echo "committed yet, and an UPDATE holds every row it has changed until it commits."
        echo "Find the transaction in the migration that held rows for over a second, and"
        echo "make each commit cover few enough rows that nobody waits that long."
        exit 1
      fi

      # --- the answers --------------------------------------------------------
      quiet=$(field what-quiet-period-buys | tr 'A-Z' 'a-z')
      if ! printf '%s' "$quiet" | grep -Eq '\b(still|same|nothing|unchanged|duration|length|long|shorten|shortens|fewer|notice|notices|witnesses|traffic|users|customers)\b'; then
        echo "not yet: 'what-quiet-period-buys:' does not separate the two things. Running it"
        echo "at 3am changes one of them and not the other: how long the table is held, and"
        echo "how many people are trying to use it while it is. Say which is which."
        exit 1
      fi

      free=$(field why-one-is-free | tr 'A-Z' 'a-z')
      if ! printf '%s' "$free" | grep -Eq '\b(rewrite|rewrites|rewriting|catalog|catalogue|metadata|missing|per-row|per row|every row|each row|copy|copies|copied|new file|relfilenode)\b'; then
        echo "not yet: 'why-one-is-free:' does not say what the expensive one has to do that"
        echo "the cheap one does not. Adding a column with a constant default stores one"
        echo "value once and hands it to every existing row on read. Changing a type cannot"
        echo "do that. Say what it has to do to each row instead."
        exit 1
      fi

      lock=$(field the-lock | tr 'A-Z' 'a-z' | tr -d '_')
      case "$lock" in
        *"access exclusive"*|*accessexclusive*) ;;
        *)
          echo "not yet: 'the-lock:' says '$(field the-lock)'. It is the strongest one Postgres"
          echo "has — the one that conflicts with every other lock mode including the one a"
          echo "plain SELECT takes, which is why readers queued. pg_locks spells it in two"
          echo "words."
          exit 1
          ;;
      esac

      echo "PASS — payments.amount is numeric and adds up, amount_cents is gone, and all"
      echo "${served} reads and ${wserved} writes that arrived during the migration were served."
