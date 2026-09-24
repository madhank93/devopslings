---
kind: lesson
title: "the transaction id age keeps climbing and vacuum says it is done"
description: |
  A monitoring check has been amber for a fortnight: the transaction id age on
  `ledger` is past its freeze threshold and rising. Autovacuum is running
  against the table — repeatedly, and unasked, on a table somebody disabled
  autovacuum on months ago. It finishes without error every time and the age
  does not move. What is holding it has no session, no lock anyone is waiting
  for, and no timeout that will ever end it.
name: xid-wraparound-warning
slug: xid-wraparound-warning
createdAt: "2026-09-24"

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
      rm -f /work/answers/wraparound.md

      # Anything a previous run left prepared.
      for g in $(P -c "SELECT gid FROM pg_prepared_xacts"); do
        P -c "ROLLBACK PREPARED '$g'" >/dev/null 2>&1 || true
      done

      P >/dev/null <<'SQL'
      DROP TABLE IF EXISTS ledger;
      CREATE TABLE ledger (
          id    bigserial PRIMARY KEY,
          entry text NOT NULL,
          cents bigint NOT NULL,
          at    timestamptz NOT NULL
      );
      -- Production runs autovacuum_freeze_max_age at its 200 million default
      -- and takes months to reach it. The sandbox runs this one table at the
      -- lowest value Postgres accepts so the same curve fits in a minute.
      -- Nothing else about the mechanism is scaled.
      ALTER TABLE ledger SET (autovacuum_freeze_max_age = 100000);
      INSERT INTO ledger (entry, cents, at)
      SELECT 'entry-' || g, g, now() - (g % 90) * interval '1 day'
      FROM generate_series(1, 20000) g;
      SQL
      P -c "VACUUM (FREEZE, ANALYZE) ledger" >/dev/null

      # The settlement run that half-finished. Its coordinator went away
      # between the prepare and the commit, months ago, and the transaction
      # has been sitting in the prepared state ever since.
      P >/dev/null <<'SQL'
      BEGIN;
      INSERT INTO ledger (entry, cents, at) VALUES ('settlement-batch-0091', 5000, now());
      PREPARE TRANSACTION 'settlement-0091';
      SQL

      # Somebody turned autovacuum off on this table when it was causing IO.
      P -c "ALTER TABLE ledger SET (autovacuum_enabled = off)" >/dev/null

      # A quarter of a million transactions' worth of ordinary traffic.
      P -c "DO \$\$ BEGIN FOR i IN 1..250000 LOOP PERFORM pg_current_xact_id(); COMMIT; END LOOP; END \$\$;" >/dev/null

      cat > /work/app/xid-age.sh <<'SH'
      #!/usr/bin/env bash
      # The monitoring check that has been amber for a fortnight.
      set -euo pipefail
      export PGPASSWORD=devopslings
      psql -X -U postgres -d shop -h 127.0.0.1 <<'SQL'
      SELECT c.relname,
             age(c.relfrozenxid) AS xid_age,
             coalesce(
               (SELECT option_value::bigint FROM pg_options_to_table(c.reloptions)
                 WHERE option_name = 'autovacuum_freeze_max_age'),
               current_setting('autovacuum_freeze_max_age')::bigint) AS freeze_max_age
        FROM pg_class c
       WHERE c.relkind = 'r' AND c.relnamespace = 'public'::regnamespace
       ORDER BY age(c.relfrozenxid) DESC
       LIMIT 5;

      SELECT datname, age(datfrozenxid) AS db_xid_age FROM pg_database WHERE datname = 'shop';
      SQL
      SH
      chmod +x /work/app/xid-age.sh

      cat > /work/answers/wraparound.md <<'MD'
      # The age that will not come down

      # What is holding the transaction id horizon. There is no session for it
      # and no lock — name the view that lists the thing, and what it is.
      what-held-it: ?

      # autovacuum_enabled was set to off on ledger months ago, and autovacuum
      # has been running against it anyway. One line: why?
      why-autovacuum-ran-anyway: ?

      # Nobody fixed it and the age kept climbing. One line: what does Postgres
      # do when it runs out of transaction ids to give out?
      what-happens-at-the-limit: ?
      MD

      echo "scenario ready"
      echo
      bash /work/app/xid-age.sh | sed 's/^/  /'
      echo
      echo "  the check:    /work/app/xid-age.sh"
      echo "  your answer:  /work/answers/wraparound.md"
      echo
      echo "  psql -h 127.0.0.1 -U postgres -d shop"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 600
    run: |
      export PGPASSWORD=devopslings
      P() { command psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 "$@"; }
      ans=/work/answers/wraparound.md

      if [ ! -s "$ans" ]; then
        echo "not yet: $ans is missing or empty"
        exit 1
      fi
      if grep -q ': *?$' "$ans" 2>/dev/null; then
        echo "not yet: $ans still has unanswered '?' fields"
        exit 1
      fi
      if [ -z "$(P -c "SELECT 1 FROM pg_class WHERE relname = 'ledger'")" ]; then
        echo "not yet: the ledger table is gone. Dropping the table does take its xid age"
        echo "with it, and it takes the ledger too. Run 'devopslings reset"
        echo "xid-wraparound-warning' to start over."
        exit 1
      fi

      field() {
        grep -E "^$1:" "$ans" 2>/dev/null | head -1 | sed "s/^$1: *//" | tr -d '\r' || true
      }

      # --- nothing may still be pinning the horizon ---------------------------
      stuck=$(P -c "SELECT string_agg(gid || ' (xid ' || transaction || ', prepared ' ||
                            to_char(prepared, 'YYYY-MM-DD') || ')', ', ') FROM pg_prepared_xacts" || true)
      if [ -n "$(printf '%s' "$stuck" | tr -d ' ')" ]; then
        echo "not yet: there is still a prepared transaction on this server: $stuck"
        echo
        echo "It has no backend, so it is in no session list, holds no lock anyone waits on,"
        echo "and no timeout applies to it — it survives restarts, because surviving a crash"
        echo "is the entire point of preparing a transaction. Until it is resolved, its"
        echo "transaction id is the oldest one the server may still need, and nothing can be"
        echo "frozen past it."
        exit 1
      fi

      # --- and the age has to have come back down -----------------------------
      thresh=$(P -c "SELECT option_value FROM pg_class c, pg_options_to_table(c.reloptions)
                      WHERE c.relname = 'ledger' AND option_name = 'autovacuum_freeze_max_age'")
      : "${thresh:=100000}"
      age=$(P -c "SELECT age(relfrozenxid) FROM pg_class WHERE relname = 'ledger'")
      : "${age:=0}"
      if [ "$age" -ge "$thresh" ]; then
        echo "not yet: ledger is ${age} transaction ids past its oldest frozen id, against a"
        echo "freeze threshold of ${thresh}. Nothing is pinning the horizon any more, so a"
        echo "freeze can finally move it — autovacuum will come round to that by itself, or"
        echo "'VACUUM (FREEZE, VERBOSE) ledger' does it now and prints the cutoff it used."
        exit 1
      fi

      rows=$(P -c "SELECT count(*) FROM ledger")
      if [ "${rows:-0}" -lt 20000 ]; then
        echo "not yet: ledger has ${rows} rows, and it had 20000 before you started. The age"
        echo "came down because the data went away, which is not the trade that was on offer."
        exit 1
      fi

      # --- the answers --------------------------------------------------------
      held=$(field what-held-it | tr 'A-Z' 'a-z')
      if ! printf '%s' "$held" | grep -Eq 'pg_prepared_xacts|prepared transaction|prepared xact|two-phase|2pc'; then
        echo "not yet: 'what-held-it:' says '${held:-nothing}'. It was not in"
        echo "pg_stat_activity, because it has no backend at all. Something was left half"
        echo "committed by a two-phase commit that never got its second phase, and there is a"
        echo "view that lists exactly those. Name it."
        exit 1
      fi

      why=$(field why-autovacuum-ran-anyway | tr 'A-Z' 'a-z')
      if ! printf '%s' "$why" | grep -Eq '\b(wraparound|anti-wraparound|antiwraparound|freeze|freezing|forced|forces|force|ignores|ignored|ignore|override|overrides|regardless|anyway|mandatory|must)\b'; then
        echo "not yet: 'why-autovacuum-ran-anyway:' does not say what overrode the setting."
        echo "autovacuum_enabled = off is a request, and there is one job it is not allowed"
        echo "to refuse, because the alternative is a database that cannot accept writes."
        echo "Name that job."
        exit 1
      fi

      limit=$(field what-happens-at-the-limit | tr 'A-Z' 'a-z')
      if ! printf '%s' "$limit" | grep -Eq '\b(refuse|refuses|refused|reject|rejects|stop|stops|stopped|shut|shuts|shutdown|read-only|readonly|single-user|halt|halts|blocks)\b'; then
        echo "not yet: 'what-happens-at-the-limit:' does not say what the database does."
        echo "It does not corrupt anything and it does not lose the old rows — it protects"
        echo "them, by taking away the only thing that could overwrite their visibility. Say"
        echo "what it stops doing, and note it is not a graceful degradation you can ride"
        echo "out."
        exit 1
      fi

      echo "PASS — no prepared transactions left, and ledger is ${age} transaction ids old"
      echo "against a freeze threshold of ${thresh}, with all ${rows} rows still in it."
