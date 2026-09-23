---
kind: lesson
title: "two jobs, one batch, and one of them is killed every night"
description: |
  Reconciliation and audit run over the same handful of orders every night.
  Most nights both finish. Some nights one of them dies with "deadlock
  detected" and the batch is left half-stamped. Nothing is locked when you go
  looking in the morning, the jobs are each correct on their own, and the thing
  they disagree about is not in either of their code paths.
name: deadlock-detected
slug: deadlock-detected
createdAt: "2026-09-23"
timingSensitive: true

sandbox:
  stack: db-stack
  service: primary

tasks:
  init_scenario:
    init: true
    timeout_seconds: 600
    run: |
      export PGPASSWORD=devopslings
      P() { command psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 "$@"; }

      install -d /work/app /work/answers
      rm -f /work/answers/deadlock.md

      # The settlement batch, rebuilt from scratch. placed_at rises with id,
      # which is the whole reason the two jobs disagree without either of them
      # looking wrong.
      P >/dev/null <<'SQL'
      DELETE FROM orders WHERE reference LIKE 'BATCH-%';
      INSERT INTO orders (customer_id, status, reference, total_cents, placed_at)
      SELECT 1 + g, 'pending', 'BATCH-' || g, 1000 + g,
             now() - (10 - g) * interval '1 day'
      FROM generate_series(1, 6) g;
      SQL

      cat > /work/app/settle.sh <<'SH'
      #!/usr/bin/env bash
      # The two nightly passes over the settlement batch.
      #
      # Both walk the same six orders. Reconciliation marks them settled;
      # the audit pass stamps them checked. They are scheduled a minute apart
      # and they overlap whenever the first one is slow.
      set -euo pipefail
      export PGPASSWORD=devopslings
      mode=${1:?usage: settle.sh reconcile|audit}
      P() { psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 "$@"; }

      case "$mode" in
        # Reconciliation works through the batch in id order.
        reconcile) order="id";             status="reconciled" ;;
        # The audit pass takes the newest first, so anything a customer might
        # be looking at right now is stamped before the old ones.
        audit)     order="placed_at DESC"; status="audited" ;;
        *) echo "unknown mode: $mode" >&2; exit 2 ;;
      esac

      ids=$(P -c "SELECT id FROM orders WHERE reference LIKE 'BATCH-%' ORDER BY $order")

      {
        echo "BEGIN;"
        for id in $ids; do
          echo "UPDATE orders SET status = '$status' WHERE id = $id;"
          # Per-row work: pull the invoice, write the ledger line. Stubbed out
          # here, and it is why the transaction stays open long enough for the
          # other job to get in between two of these.
          echo "SELECT pg_sleep(0.05);"
        done
        echo "COMMIT;"
      } | P >/dev/null

      echo "$mode: stamped $(printf '%s\n' $ids | wc -l | tr -d ' ') orders $status"
      SH
      chmod +x /work/app/settle.sh

      cat > /work/answers/deadlock.md <<'MD'
      # Two jobs, one batch

      # Postgres did not wait the cycle out. What did it do, and to which of
      # the two transactions?
      what-postgres-did: ?

      # Both jobs walk the same six rows. Name the two columns they sort by —
      # they are not the same column, and that is the bug.
      the-two-orders: ?

      # One line: why does catching the error and retrying the transaction not
      # make this go away?
      why-not-retry: ?
      MD

      echo "scenario ready — six orders in the batch, both jobs stamp all six"
      echo
      echo "  the jobs:     /work/app/settle.sh reconcile"
      echo "                /work/app/settle.sh audit"
      echo "  your answer:  /work/answers/deadlock.md"
      echo
      echo "Run them at the same time, the way cron does:"
      echo
      echo "  /work/app/settle.sh reconcile & /work/app/settle.sh audit & wait"
      echo
      echo "  psql -h 127.0.0.1 -U postgres -d shop"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 600
    run: |
      export PGPASSWORD=devopslings
      P() { command psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 "$@"; }
      ans=/work/answers/deadlock.md
      app=/work/app/settle.sh

      if [ ! -s "$ans" ]; then
        echo "not yet: $ans is missing or empty"
        exit 1
      fi
      if grep -q ': *?$' "$ans" 2>/dev/null; then
        echo "not yet: $ans still has unanswered '?' fields"
        exit 1
      fi
      if [ ! -s "$app" ]; then
        echo "not yet: $app is missing or empty. Both jobs still have to run."
        echo "Run 'devopslings reset deadlock-detected' to put the scenario back."
        exit 1
      fi

      field() {
        grep -E "^$1:" "$ans" 2>/dev/null | head -1 | sed "s/^$1: *//" | tr -d '\r' || true
      }
      deadlocks() { P -c "SELECT deadlocks FROM pg_stat_database WHERE datname = 'shop'"; }
      batch_status() {
        P -c "SELECT count(*) FROM orders WHERE reference LIKE 'BATCH-%' AND status = '$1'"
      }

      # --- both jobs still have to do the whole batch -------------------------
      # Run each on its own first. Nothing can deadlock here, so anything that
      # fails is the job itself, not the interaction.
      for mode in reconcile audit; do
        case "$mode" in reconcile) want=reconciled ;; audit) want=audited ;; esac
        P -c "UPDATE orders SET status = 'pending' WHERE reference LIKE 'BATCH-%'" >/dev/null
        rc=0
        timeout 120 bash "$app" "$mode" >/tmp/grader-$mode.log 2>&1 || rc=$?
        if [ "$rc" != "0" ]; then
          echo "not yet: '$app $mode' failed on its own, with nothing else running:"
          tail -3 /tmp/grader-$mode.log | sed 's/^/    /'
          exit 1
        fi
        stamped=$(batch_status "$want")
        if [ "${stamped:-0}" != "6" ]; then
          echo "not yet: '$app $mode' ran alone and left ${stamped:-0} of the 6 batch orders"
          echo "marked '$want'. Both jobs still have the whole batch to get through — a pass"
          echo "that touches fewer rows has fewer rows to collide on, which is not the same"
          echo "thing as the collision being fixed."
          exit 1
        fi
      done

      # --- and they have to survive running together --------------------------
      before=$(deadlocks)
      : "${before:=0}"
      rounds=4
      failed=""
      for round in $(seq 1 $rounds); do
        P -c "UPDATE orders SET status = 'pending' WHERE reference LIKE 'BATCH-%'" >/dev/null
        rc_a=0; rc_b=0
        timeout 120 bash "$app" reconcile >/tmp/grader-round-a.log 2>&1 & pa=$!
        timeout 120 bash "$app" audit     >/tmp/grader-round-b.log 2>&1 & pb=$!
        wait $pa || rc_a=$?
        wait $pb || rc_b=$?
        if [ "$rc_a" != "0" ] || [ "$rc_b" != "0" ]; then
          failed="$round"
          break
        fi
      done

      sleep 1
      after=$(deadlocks)
      : "${after:=0}"
      delta=$(( after - before ))

      if [ -n "$failed" ]; then
        echo "not yet: round $failed of $rounds killed one of the two jobs:"
        echo
        { grep -iE 'deadlock|ERROR' /tmp/grader-round-a.log /tmp/grader-round-b.log 2>/dev/null || true; } | head -3 | sed 's/^/    /'
        echo
        echo "Postgres counted $delta deadlock(s) on the database while that ran. Neither job"
        echo "is wrong on its own — each one takes the same six rows and each one takes them"
        echo "in an order that made sense to whoever wrote it. Compare the two orders."
        exit 1
      fi
      if [ "$delta" -gt 0 ]; then
        echo "not yet: both jobs came back reporting success and pg_stat_database still"
        echo "counted $delta deadlock(s) while they ran. Something is swallowing the error and"
        echo "going round again: the server detected the cycle, waited out deadlock_timeout,"
        echo "picked a victim and rolled its work back, and only then did the retry start"
        echo "over. The cycle is still being formed — a retry decides who pays for it, not"
        echo "whether it happens."
        exit 1
      fi

      # --- the answers --------------------------------------------------------
      did=$(field what-postgres-did | tr 'A-Z' 'a-z')
      if ! printf '%s' "$did" | grep -Eq '\b(abort|aborted|aborts|cancel|cancelled|canceled|kill|killed|terminate|terminated|rollback|rolled|roll|victim)\b'; then
        echo "not yet: 'what-postgres-did:' does not say what happened to the losing side."
        echo "It did not wait, and it did not let both through. One transaction was chosen"
        echo "and something was done to it — the error message names the act, and the server"
        echo "log names which process it was done to."
        exit 1
      fi

      orders=$(field the-two-orders | tr 'A-Z' 'a-z')
      if ! printf '%s' "$orders" | grep -Eq '\bid\b' || ! printf '%s' "$orders" | grep -Eq '\bplaced_at\b'; then
        echo "not yet: 'the-two-orders:' says '${orders:-nothing}'. Both jobs select the same"
        echo "six rows and each sorts them before it starts updating. Read the two ORDER BY"
        echo "clauses in $app and name both columns."
        exit 1
      fi

      why=$(field why-not-retry | tr 'A-Z' 'a-z')
      if ! printf '%s' "$why" | grep -Eq '\b(again|same|still|recur|recurs|repeat|repeats|order|ordering|cause|underlying|symptom|collide|collides|happen|happens)\b'; then
        echo "not yet: 'why-not-retry:' does not say what the retry leaves in place. A retry"
        echo "that succeeds is a real thing to have — it just runs after the server has"
        echo "already waited out deadlock_timeout and thrown a transaction's work away. Say"
        echo "what is still true on the next run that was true on this one."
        exit 1
      fi

      echo "PASS — both jobs finish the whole batch alone, and $rounds rounds of the two"
      echo "running together added no deadlocks to pg_stat_database."
