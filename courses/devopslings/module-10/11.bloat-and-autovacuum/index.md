---
kind: lesson
title: "the table is ten times its data size and nothing was inserted"
description: |
  `inventory` holds fifty thousand rows and has held fifty thousand rows all
  week. The file behind it is ten times the size of the data in it and still
  growing. Autovacuum is running, is not erroring, and is reclaiming nothing —
  and the reason is a session that has not run a statement since Tuesday.
name: bloat-and-autovacuum
slug: bloat-and-autovacuum
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
      rm -f /work/answers/bloat.md

      P -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
             WHERE datname = 'shop' AND application_name = 'stock-report'" >/dev/null

      P >/dev/null <<'SQL'
      DROP TABLE IF EXISTS inventory;
      CREATE TABLE inventory (
          sku        text PRIMARY KEY,
          qty        int NOT NULL,
          updated_at timestamptz NOT NULL
      );
      INSERT INTO inventory SELECT 'SKU-' || g, 100, now() FROM generate_series(1, 50000) g;
      SQL
      P -c "VACUUM (ANALYZE) inventory" >/dev/null

      base=$(P -c "SELECT pg_relation_size('inventory')")
      printf '%s\n' "$base" > /work/app/base-size.txt
      P -c "SELECT relfilenode FROM pg_class WHERE relname = 'inventory'" > /work/app/relfilenode.txt

      cat > /work/app/stock-report.sh <<'SH'
      #!/usr/bin/env bash
      # The weekly stock report: a dozen queries under one repeatable-read
      # snapshot, so the figures agree with each other, then the spreadsheet
      # step.
      set -euo pipefail
      export PGPASSWORD=devopslings
      {
        echo "BEGIN ISOLATION LEVEL REPEATABLE READ;"
        echo "SELECT count(*), sum(qty) FROM inventory;"
        sleep 86400
      } | psql -qtAX -U postgres -d shop -h 127.0.0.1 \
            -c "SET application_name = 'stock-report'" -f - >/dev/null 2>&1
      SH
      chmod +x /work/app/stock-report.sh

      cat > /work/app/restock.sh <<'SH'
      #!/usr/bin/env bash
      # One pass of the restock job: every sku gets its count refreshed.
      # It runs every few minutes, all day, and it inserts nothing.
      set -euo pipefail
      export PGPASSWORD=devopslings
      rounds=${1:-1}
      P() { psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 "$@"; }
      for r in $(seq 1 "$rounds"); do
        P -c "UPDATE inventory SET qty = qty + 1, updated_at = now()" >/dev/null
      done
      echo "$rounds pass(es) — inventory is now $(P -c "SELECT pg_size_pretty(pg_relation_size('inventory'))")"
      SH
      chmod +x /work/app/restock.sh

      # The report that never finished. setsid on the whole script, not on
      # psql alone: the transaction lives as long as the pipe feeding it, and
      # a pipe whose writer is reaped closes immediately.
      # Wrapped so the orphan always exits 0: it is reparented to the postmaster,
      # which crash-restarts the server when an unknown child exits non-0/1.
      setsid bash -c "bash /work/app/stock-report.sh >/dev/null 2>&1; exit 0" </dev/null >/dev/null 2>&1 &
      held=no
      for _ in $(seq 1 30); do
        s=$(P -c "SELECT state FROM pg_stat_activity WHERE application_name = 'stock-report'" || true)
        if [ "$s" = "idle in transaction" ]; then held=yes; break; fi
        sleep 1
      done
      if [ "$held" != "yes" ]; then
        echo "scenario did not establish: the stock report never opened its transaction" >&2
        exit 1
      fi

      # A week of restocking, compressed.
      bash /work/app/restock.sh 10 >/dev/null
      sleep 2

      cat > /work/answers/bloat.md <<'MD'
      # Ten times the data, none of it inserted

      # What is stopping autovacuum reclaiming the dead rows. Name the state
      # the session is in, and the pg_stat_activity column that shows how far
      # back it is holding the horizon.
      what-held-it: ?

      # VACUUM FULL would hand the disk space straight back. One line: why is
      # it the wrong instrument on a table that is being served?
      why-not-vacuum-full: ?

      # After a plain VACUUM the file on disk is still exactly as big. One
      # line: what did that VACUUM achieve, then?
      what-vacuum-achieved: ?
      MD

      echo "scenario ready"
      echo
      echo "  inventory:    $(P -c "SELECT count(*) FROM inventory") rows,"
      echo "                $(P -c "SELECT pg_size_pretty(pg_relation_size('inventory'))") on disk against $(P -c "SELECT pg_size_pretty($base)") of data"
      echo
      echo "  the restock:  /work/app/restock.sh [passes]"
      echo "  your answer:  /work/answers/bloat.md"
      echo
      echo "  psql -h 127.0.0.1 -U postgres -d shop"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 900
    run: |
      export PGPASSWORD=devopslings
      P() { command psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 "$@"; }
      ans=/work/answers/bloat.md

      if [ ! -s "$ans" ]; then
        echo "not yet: $ans is missing or empty"
        exit 1
      fi
      if grep -q ': *?$' "$ans" 2>/dev/null; then
        echo "not yet: $ans still has unanswered '?' fields"
        exit 1
      fi
      if [ ! -s /work/app/base-size.txt ] || [ ! -s /work/app/relfilenode.txt ]; then
        echo "not yet: the scenario's recorded 'before' figures are gone. Run"
        echo "'devopslings reset bloat-and-autovacuum' to take them again."
        exit 1
      fi

      field() {
        grep -E "^$1:" "$ans" 2>/dev/null | head -1 | sed "s/^$1: *//" | tr -d '\r' || true
      }
      size()  { P -c "SELECT pg_relation_size('inventory')"; }
      dead()  { P -c "SELECT coalesce(n_dead_tup, 0) FROM pg_stat_user_tables WHERE relname = 'inventory'"; }
      node()  { P -c "SELECT relfilenode FROM pg_class WHERE relname = 'inventory'"; }

      if [ -z "$(P -c "SELECT 1 FROM pg_class WHERE relname = 'inventory'")" ]; then
        echo "not yet: the inventory table is gone. Dropping it and building it again is a"
        echo "rewrite with extra steps, and the restock job it serves was never offline."
        echo "Run 'devopslings reset bloat-and-autovacuum' to start over."
        exit 1
      fi

      # --- nothing may still be holding the horizon ---------------------------
      holder=$(P -c "SELECT string_agg(coalesce(application_name, '?') || ' (' || state ||
                              ', xmin ' || backend_xmin::text || ')', ', ')
                       FROM pg_stat_activity
                      WHERE datname = 'shop' AND pid <> pg_backend_pid()
                        AND backend_type = 'client backend'
                        AND backend_xmin IS NOT NULL" || true)
      if [ -n "$(printf '%s' "$holder" | tr -d ' ')" ]; then
        echo "not yet: a session is still holding a snapshot open: $holder"
        echo
        echo "backend_xmin is the oldest transaction id that session still needs to be able"
        echo "to see, and nothing newer than it may be removed — anywhere in the database, by"
        echo "any vacuum. So vacuum runs on schedule, finds hundreds of thousands of dead"
        echo "rows, and reports that none of them are removable yet."
        exit 1
      fi

      # --- and the table must not have been rewritten under the traffic -------
      want_node=$(tr -dc '0-9' < /work/app/relfilenode.txt)
      got_node=$(node)
      if [ "${got_node:-0}" != "${want_node:-x}" ]; then
        echo "not yet: inventory has a different relfilenode than it started with"
        echo "(${want_node} then, ${got_node} now), so the table was rewritten — VACUUM FULL,"
        echo "CLUSTER, or a copy into a new table. That does give the disk space back, and it"
        echo "holds an ACCESS EXCLUSIVE lock on the table for the whole rewrite: every"
        echo "restock pass and every read queues behind it. The restock job is not allowed to"
        echo "stop. Reset the lesson and reclaim it without taking the table away."
        exit 1
      fi

      # --- the dead rows have to be gone --------------------------------------
      d=$(dead)
      : "${d:=0}"
      if [ "$d" -gt 150000 ]; then
        echo "not yet: inventory still shows ${d} dead row versions — three restock passes"
        echo "worth would be 150000, so that is a backlog, not the last few minutes. Nothing"
        echo "is holding the"
        echo "horizon any more, so they are removable now — autovacuum will get to it within"
        echo "a naptime on its own, or you can stop waiting and do it yourself. Either way"
        echo "the check is looking at n_dead_tup in pg_stat_user_tables."
        exit 1
      fi

      # --- and the space has to be going back into the table ------------------
      base=$(tr -dc '0-9' < /work/app/base-size.txt)
      before=$(size)
      bash /work/app/restock.sh 10 >/dev/null 2>&1 || true
      sleep 2
      after=$(size)
      # Put back what the measurement cost: ten passes of the grader's own make
      # half a million dead rows, and the next run must not be grading those.
      P -c "VACUUM inventory" >/dev/null
      grew=$(( (after - before) * 100 / (before > 0 ? before : 1) ))
      if [ "$grew" -gt 40 ]; then
        echo "not yet: ten more restock passes grew inventory by ${grew}% (from ${before} to"
        echo "${after} bytes). Each pass replaces every row, and the space the old versions"
        echo "held should be going back into the table for the next pass to use. If the file"
        echo "is still growing pass after pass, nothing is reclaiming it."
        exit 1
      fi

      # --- the answers --------------------------------------------------------
      held=$(field what-held-it | tr 'A-Z' 'a-z')
      if ! printf '%s' "$held" | grep -Eq '\b(idle|open|long-lived|long|uncommitted)\b' \
         || ! printf '%s' "$held" | grep -Eq 'xmin|horizon|snapshot'; then
        echo "not yet: 'what-held-it:' says '${held:-nothing}'. Two things are wanted: what"
        echo "state pg_stat_activity reported that session in — it was not running anything —"
        echo "and the column on the same row that gives the oldest transaction id it still"
        echo "needs to be able to see."
        exit 1
      fi

      vf=$(field why-not-vacuum-full | tr 'A-Z' 'a-z')
      if ! printf '%s' "$vf" | grep -Eq '\b(lock|locks|locked|exclusive|block|blocks|blocking|offline|downtime|unavailable|outage|queue|queues|rewrite|rewrites|copy|copies|double|twice)\b'; then
        echo "not yet: 'why-not-vacuum-full:' does not say what it costs. It is not that it"
        echo "fails — it works, and it is the only thing here that shrinks the file. Say what"
        echo "it does to everything else trying to use the table while it runs, and what it"
        echo "needs on disk to do it."
        exit 1
      fi

      ach=$(field what-vacuum-achieved | tr 'A-Z' 'a-z')
      if ! printf '%s' "$ach" | grep -Eq '\b(reuse|reusable|reused|reusing|free|freed|frees|available|space map|fsm)\b'; then
        echo "not yet: 'what-vacuum-achieved:' does not say what changed, given the file is"
        echo "the same size. The dead row versions are gone and the pages they were in are"
        echo "still there — so what can the next restock pass do with those pages that it"
        echo "could not do before?"
        exit 1
      fi

      echo "PASS — nothing is holding the horizon, inventory shows ${d} dead rows, it is the"
      echo "same file it always was, and ten more restock passes grew it ${grew}% against"
      echo "$(( before / 1024 ))kB (data is $(( base / 1024 ))kB)."
