---
kind: lesson
title: "checkout writes at a third of the speed it did in spring"
description: |
  Nothing about the insert changed. The table is the same shape, the hardware
  is the same, and the statement is the same statement. What changed is how
  many indexes it has to maintain: six of them now, added one at a time by
  people fixing real read problems, and nobody has asked since whether any
  query still uses them.
name: index-that-costs-more-than-it-saves
slug: index-that-costs-more-than-it-saves
createdAt: "2026-09-23"
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
      rm -f /work/answers/index-cost.md

      # Whatever the last run or the last lesson left on orders, back to the
      # four the schema ships with, then the two that were added since.
      P >/dev/null <<'SQL'
      SET client_min_messages = warning;
      DO $$
      DECLARE i text;
      BEGIN
        FOR i IN
          SELECT indexname FROM pg_indexes
          WHERE schemaname = 'public' AND tablename = 'orders'
            AND indexname NOT IN ('orders_pkey', 'orders_customer_id_idx',
                                  'orders_placed_at_idx', 'orders_reference_idx')
        LOOP
          EXECUTE format('DROP INDEX IF EXISTS public.%I', i);
        END LOOP;
      END $$;

      CREATE INDEX IF NOT EXISTS orders_customer_id_idx ON orders (customer_id);
      CREATE INDEX IF NOT EXISTS orders_placed_at_idx   ON orders (placed_at);
      CREATE INDEX IF NOT EXISTS orders_reference_idx   ON orders (reference);

      -- Support asked for case-insensitive reference search in March. The
      -- search was built against reference directly and this was never
      -- removed.
      CREATE INDEX orders_lower_reference_idx ON orders (lower(reference));

      -- The nightly dedupe job hashed references to find duplicates. The job
      -- was retired in June.
      CREATE INDEX orders_reference_md5_idx ON orders (md5(reference));

      -- Rows an interrupted benchmark left behind.
      DELETE FROM orders WHERE reference LIKE 'BM-%';
      SQL

      cat > /work/app/bench.sh <<'SH'
      #!/usr/bin/env bash
      # The write path, timed: one batch of checkout-shaped inserts.
      #
      # The values are random across customers, references and dates on
      # purpose. An append-only batch only ever touches the right-hand edge of
      # each index, which is the cheapest thing a B-tree ever does and hides
      # exactly the cost this is here to measure.
      set -euo pipefail
      export PGPASSWORD=devopslings
      rows=${1:-50000}
      P() { psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 "$@"; }

      P -c "CHECKPOINT" >/dev/null
      high=$(P -c "SELECT max(id) FROM orders")

      start=$(date +%s%N)
      P -c "INSERT INTO orders (customer_id, status, reference, total_cents, placed_at)
            SELECT 1 + (random() * 199999)::int,
                   'placed',
                   'BM-' || (random() * 999999999)::bigint::text,
                   100 + (g % 90000),
                   now() - (random() * 900)::int * interval '1 day'
            FROM generate_series(1, $rows) g" >/dev/null
      ms=$(( ($(date +%s%N) - start) / 1000000 ))

      # By id range, not by reference: finding the batch any other way is a
      # scan of ten million rows and would cost more than the measurement.
      P -c "DELETE FROM orders WHERE id > $high" >/dev/null

      echo "inserted $rows rows in ${ms}ms"
      echo "rows_per_sec=$(( rows * 1000 / ms ))"
      SH
      chmod +x /work/app/bench.sh

      cat > /work/app/workload.sql <<'SQL'
      -- Every read this table serves in production. There is nothing else.
      --
      -- order lookup by id, from the admin tool
      SELECT id, status, total_cents FROM orders WHERE id = 4321987;

      -- customer support looking an order up by the reference on the email
      SELECT id, status, total_cents FROM orders WHERE reference = '5500000';

      -- the customer's own order history page, newest first
      SELECT id, status, placed_at FROM orders
       WHERE customer_id = 12345 ORDER BY placed_at DESC LIMIT 20;

      -- the daily volume figure on the ops dashboard
      SELECT count(*) FROM orders
       WHERE placed_at >= date_trunc('day', now() - interval '30 days')
         AND placed_at <  date_trunc('day', now() - interval '29 days');
      SQL

      # The "before" number, measured here so it is this machine's number and
      # not a figure from someone else's laptop.
      rate=$(bash /work/app/bench.sh | sed -n 's/^rows_per_sec=//p')
      printf '%s\n' "$rate" > /work/app/baseline.txt

      cat > /work/answers/index-cost.md <<'MD'
      # Six indexes on orders

      # The view that says how many times each index has actually been used
      # since the counters were last reset.
      usage-view: ?

      # What Postgres has to do on every inserted row for each index on the
      # table — the per-index cost all six were charging.
      write-cost: ?

      # An idx_scan of 0 is not by itself proof that an index is dead. One
      # line: what can make an index that is genuinely needed read zero?
      why-zero-is-not-proof: ?
      MD

      echo "scenario ready — orders has $(P -c "SELECT count(*) FROM pg_indexes WHERE tablename = 'orders'") indexes"
      echo
      echo "  writes now:   ${rate} rows/sec (recorded in /work/app/baseline.txt)"
      echo "  the writes:   /work/app/bench.sh [rows]"
      echo "  the reads:    /work/app/workload.sql — every query this table serves"
      echo "  your answer:  /work/answers/index-cost.md"
      echo
      echo "  psql -h 127.0.0.1 -U postgres -d shop"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 600
    run: |
      export PGPASSWORD=devopslings
      P() { command psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 "$@"; }
      ans=/work/answers/index-cost.md
      bench=/work/app/bench.sh

      if [ ! -s "$ans" ]; then
        echo "not yet: $ans is missing or empty"
        exit 1
      fi
      if grep -q ': *?$' "$ans" 2>/dev/null; then
        echo "not yet: $ans still has unanswered '?' fields"
        exit 1
      fi
      if [ ! -s "$bench" ] || [ ! -s /work/app/baseline.txt ]; then
        echo "not yet: $bench or /work/app/baseline.txt is missing. The measurement has to"
        echo "run. Use 'devopslings reset index-that-costs-more-than-it-saves'."
        exit 1
      fi

      field() {
        grep -E "^$1:" "$ans" 2>/dev/null | head -1 | sed "s/^$1: *//" | tr -d '\r' || true
      }

      # --- the reads still have to work --------------------------------------
      # The grader keeps its own copy of the workload. A check that read the
      # queries out of a file the student can edit would grade whatever was
      # left in the file.
      q1="SELECT id, status, total_cents FROM orders WHERE id = 4321987"
      q2="SELECT id, status, total_cents FROM orders WHERE reference = '5500000'"
      q3="SELECT id, status, placed_at FROM orders WHERE customer_id = 12345 ORDER BY placed_at DESC LIMIT 20"
      q4="SELECT count(*) FROM orders WHERE placed_at >= date_trunc('day', now() - interval '30 days') AND placed_at < date_trunc('day', now() - interval '29 days')"

      # Counters to zero, so what follows measures this run and not the term.
      P -c "SELECT pg_stat_reset_single_table_counters(indexrelid)
              FROM pg_stat_user_indexes WHERE relname = 'orders'" >/dev/null

      n=0
      for q in "$q1" "$q2" "$q3" "$q4"; do
        n=$(( n + 1 ))
        plan=$(P -c "EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) $q" 2>&1)
        if printf '%s' "$plan" | grep -q 'Seq Scan on orders'; then
          echo "not yet: query $n of the workload now reads the whole table:"
          echo
          printf '%s\n' "$q" | sed 's/^/    /'
          echo
          printf '%s\n' "$plan" | grep -E 'Scan|Filter' | head -4 | sed 's/^/    /'
          echo
          echo "Ten million rows on every call. Something this query depended on is gone —"
          echo "an index is only dead weight if nothing reads through it, and the way to know"
          echo "which is which is to ask, not to guess from the name."
          exit 1
        fi
      done

      # --- and every index left has to be one of the reasons ------------------
      sleep 2
      unused=$(P -c "SELECT indexrelname FROM pg_stat_user_indexes
                      WHERE relname = 'orders' AND idx_scan = 0
                      ORDER BY indexrelname" | tr '\n' ' ')
      if [ -n "$(printf '%s' "$unused" | tr -d ' ')" ]; then
        echo "not yet: the whole workload ran and these indexes on orders were not read once:"
        echo
        for i in $unused; do
          echo "    $i  ($(P -c "SELECT pg_size_pretty(pg_relation_size('$i'::regclass))"))"
        done
        echo
        echo "Every one of them is still maintained on every insert. If a query needs it,"
        echo "that query is not in /work/app/workload.sql and belongs there; if none does,"
        echo "it is costing writes and returning nothing."
        exit 1
      fi

      # --- the answers --------------------------------------------------------
      view=$(field usage-view | tr 'A-Z' 'a-z')
      case "$view" in
        *pg_stat_user_indexes*|*pg_stat_all_indexes*|*pg_stat_user_tables*) ;;
        *)
          echo "not yet: 'usage-view:' says '${view:-nothing}'. There is a statistics view with"
          echo "one row per index and an idx_scan column counting the times the planner has"
          echo "actually gone through it. Its name is the one to give."
          exit 1
          ;;
      esac

      cost=$(field write-cost | tr 'A-Z' 'a-z')
      if ! printf '%s' "$cost" | grep -Eq '\b(entry|entries|tuple|tuples|pointer|pointers|wal|b-tree|btree|split|splits|maintain|maintains|maintained)\b'; then
        echo "not yet: 'write-cost:' does not name what the insert is actually paying. It is"
        echo "not the disk space. One inserted row means one more thing put into each index"
        echo "— find the word for that thing, and remember it is written to the WAL as well"
        echo "as to the index."
        exit 1
      fi

      why=$(field why-zero-is-not-proof | tr 'A-Z' 'a-z')
      if ! printf '%s' "$why" | grep -Eq '\b(reset|restart|restarted|rare|rarely|occasional|occasionally|periodic|monthly|quarterly|yearly|annual|unique|constraint|primary|replica|standby|failover|window|recently|since)\b'; then
        echo "not yet: 'why-zero-is-not-proof:' does not give a case where the counter lies."
        echo "The number counts scans since the statistics were last reset, on this server"
        echo "only, and some indexes are doing a job the planner never calls on. Name one"
        echo "such case."
        exit 1
      fi

      # --- and the writes have to have come back ------------------------------
      base=$(tr -dc '0-9' < /work/app/baseline.txt)
      : "${base:=0}"
      if [ "$base" -lt 1 ]; then
        echo "not yet: /work/app/baseline.txt does not hold a rate. Reset the lesson so the"
        echo "'before' measurement is taken again."
        exit 1
      fi

      now=$(timeout 300 bash "$bench" | sed -n 's/^rows_per_sec=//p' | tail -1)
      : "${now:=0}"
      if [ "$now" -lt 1 ]; then
        echo "not yet: $bench did not print a rows_per_sec line, so there is nothing to"
        echo "compare. Reset the lesson to put the measurement back."
        exit 1
      fi
      if [ "$now" -lt $(( base * 2 )) ]; then
        echo "not yet: the write path does ${now} rows/sec against the ${base} rows/sec it"
        echo "managed with all six indexes — not the recovery that dropping dead weight off"
        echo "the insert path should buy. Every index still on the table is still being"
        echo "maintained per row; count what is left and what each one is for."
        exit 1
      fi

      left=$(P -c "SELECT count(*) FROM pg_indexes WHERE tablename = 'orders'")
      echo "PASS — orders is down to ${left} indexes, every one of them read by the workload,"
      echo "and the write path went from ${base} to ${now} rows/sec."
