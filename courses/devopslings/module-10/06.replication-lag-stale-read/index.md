---
kind: lesson
title: "the order was placed, and the order page says no such order"
description: |
  Checkout writes to the primary and the order page reads from the replica.
  The write commits, the customer is told the order is placed, and the page
  they land on a moment later cannot find it. Nothing errored, nothing was
  rolled back — the read went to a copy of the database that is telling the
  truth about a slightly earlier moment.
name: replication-lag-stale-read
slug: replication-lag-stale-read
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
      R() { command psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h replica "$@"; }

      install -d /work/app /work/answers
      rm -f /work/answers/replication-lag.md

      # A rerun inherits whatever the last one left on the replica. Put it back
      # to a plain streaming standby before the scenario sets its own fault.
      R -c "ALTER SYSTEM RESET recovery_min_apply_delay" -c "SELECT pg_reload_conf()" >/dev/null
      R -c "SELECT pg_wal_replay_resume() WHERE pg_is_wal_replay_paused()" >/dev/null
      P -c "DELETE FROM orders WHERE reference LIKE 'CO-%'" >/dev/null

      cat > /work/app/checkout.sh <<'SH'
      #!/usr/bin/env bash
      # Checkout, and the order page the customer lands on immediately after.
      #
      # The write goes to the primary because it has to. The read goes to the
      # replica because that is what the replica is for: order pages are most
      # of the read traffic on this table.
      set -euo pipefail
      export PGPASSWORD=devopslings

      primary() { psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 "$@"; }
      replica() { psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h replica    "$@"; }

      ref="CO-$(date +%s)-$$"

      id=$(primary -c "SET application_name = 'checkout'" \
                   -c "INSERT INTO orders (customer_id, status, reference, total_cents, placed_at)
                       VALUES (1, 'placed', '$ref', 4999, now()) RETURNING id")
      echo "checkout: placed $ref as order $id"

      status=$(replica -c "SET application_name = 'order-page'" \
                       -c "SELECT status FROM orders WHERE reference = '$ref'")

      if [ -z "$status" ]; then
        echo "order-page: MISSING $ref"
        exit 1
      fi
      echo "order-page: $ref is $status"
      SH
      chmod +x /work/app/checkout.sh

      cat > /work/answers/replication-lag.md <<'MD'
      # The order page that cannot find the order

      # What the replica is doing with the WAL it is receiving. One word.
      replica-replay: ?

      # The function on the replica that says how far replay has actually got,
      # so lag can be a number rather than a feeling.
      lag-position: ?

      # Sending every read to the primary makes the stale read go away. One
      # line: why is that not the fix?
      why-not-all-primary: ?
      MD

      echo "scenario ready — checkout works and the order page does not"
      echo
      echo "  the app:      /work/app/checkout.sh"
      echo "  your answer:  /work/answers/replication-lag.md"
      echo
      echo "Run it:"
      echo
      echo "  /work/app/checkout.sh"
      echo
      echo "  primary: psql -h 127.0.0.1 -U postgres -d shop"
      echo "  replica: psql -h replica    -U postgres -d shop"

      # The fault itself, set last so nothing above races it.
      R -c "SELECT pg_wal_replay_pause()" >/dev/null

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 600
    run: |
      export PGPASSWORD=devopslings
      R() { command psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h replica "$@"; }
      ans=/work/answers/replication-lag.md
      app=/work/app/checkout.sh

      if [ ! -s "$ans" ]; then
        echo "not yet: $ans is missing or empty"
        exit 1
      fi
      if grep -q ': *?$' "$ans" 2>/dev/null; then
        echo "not yet: $ans still has unanswered '?' fields"
        exit 1
      fi
      if [ ! -s "$app" ]; then
        echo "not yet: $app is missing or empty. The checkout still has to run."
        echo "Run 'devopslings reset replication-lag-stale-read' to put the scenario back."
        exit 1
      fi

      field() {
        grep -E "^$1:" "$ans" 2>/dev/null | head -1 | sed "s/^$1: *//" | tr -d '\r' || true
      }

      paused=$(R -c "SELECT pg_is_wal_replay_paused()" || true)
      if [ "${paused:-t}" != "f" ]; then
        echo "not yet: the replica is still not replaying WAL. It is receiving it —"
        echo "pg_last_wal_receive_lsn() keeps moving — and stopping before it applies"
        echo "any of it, so the gap grows for as long as it stays that way. This is a"
        echo "state somebody put it in, not a network problem, and there is a function"
        echo "that puts it back."
        exit 1
      fi

      got_replay=$(field replica-replay | tr 'A-Z' 'a-z')
      case "$got_replay" in
        *paus*) ;;
        *)
          echo "not yet: 'replica-replay:' says '${got_replay:-nothing}'. Ask the replica"
          echo "itself — pg_is_wal_replay_paused() returns true for exactly one condition,"
          echo "and that condition is the word this field wants."
          exit 1
          ;;
      esac

      got_pos=$(field lag-position | tr -d ' ()' | tr 'A-Z' 'a-z')
      case "$got_pos" in
        *pg_last_wal_replay_lsn*|*replay_lsn*) ;;
        *pg_last_wal_receive_lsn*|*receive_lsn*)
          echo "not yet: 'lag-position:' names the receive position. That is how much WAL"
          echo "has arrived, which kept advancing this whole time — a replica can be"
          echo "fully caught up on receiving and hours behind on reading. You want the"
          echo "position replay has reached."
          exit 1
          ;;
        *)
          echo "not yet: 'lag-position:' says '$(field lag-position)'. On a standby there"
          echo "is a pair of pg_lsn functions, one for how far WAL has been received and"
          echo "one for how far it has been replayed; pg_wal_lsn_diff() turns either into"
          echo "bytes. Name the replay one."
          exit 1
          ;;
      esac

      why=$(field why-not-all-primary | tr 'A-Z' 'a-z')
      if ! printf '%s' "$why" | grep -Eq '\b(load|traffic|capacity|scale|scaling|offload|off-load|overload|throughput|contention|pointless|useless|purpose|idle|wasted|waste|spare)\b'; then
        echo "not yet: 'why-not-all-primary:' does not say what is lost. Correctness is"
        echo "not the argument — reading the primary is always correct. Say what the"
        echo "replica was carrying, and what happens to the primary once it carries all"
        echo "of it again."
        exit 1
      fi

      # The durable half: replay being unpaused is not the same as lag being
      # zero, and a replica is behind by some amount at all times. Put a known
      # delay in the way and require the app to still be right.
      cleanup() {
        R -c "ALTER SYSTEM RESET recovery_min_apply_delay" -c "SELECT pg_reload_conf()" >/dev/null 2>&1 || true
      }
      trap cleanup EXIT

      scans() {
        R -c "SELECT coalesce(seq_scan,0) + coalesce(idx_scan,0)
                FROM pg_stat_user_tables WHERE relname = 'orders'" 2>/dev/null || echo 0
      }

      # Two runs against two different amounts of lag. A fix that waits for the
      # replica to catch up finishes in step with the delay; a fixed sleep does
      # not, and neither does anything that never waits at all.
      run_against() {
        delay=$1
        R -c "ALTER SYSTEM SET recovery_min_apply_delay = '${delay}s'" -c "SELECT pg_reload_conf()" >/dev/null
        sleep 1
        before=$(scans)
        started=$(date +%s)
        rc=0
        timeout 120 bash "$app" >/tmp/grader-checkout-${delay}.log 2>&1 || rc=$?
        took=$(( $(date +%s) - started ))
        after=$(scans)
        delta=$(( after - before ))
      }

      run_against 4
      rc4=$rc; took4=$took; delta4=$delta
      if [ "$rc4" != "0" ]; then
        echo "not yet: with the replica 4s behind, $app failed:"
        tail -3 /tmp/grader-checkout-4.log | sed 's/^/    /'
        echo "The write committed on the primary. The order page read a copy that had"
        echo "not applied that commit yet — that gap is the normal condition of a"
        echo "replica, not a fault, and the page has to be correct in spite of it."
        exit 1
      fi
      if [ "$delta4" -lt 1 ]; then
        echo "not yet: $app succeeded, but the replica served no read of orders while it"
        echo "ran — pg_stat_user_tables counted $delta4 new scans of the table there. The"
        echo "order page is now on the primary, which is correct and gives back every"
        echo "bit of read traffic the replica was taking. Keep the page on the replica"
        echo "and make it wait for the row it just wrote."
        exit 1
      fi

      run_against 12
      rc12=$rc; took12=$took; delta12=$delta
      if [ "$rc12" != "0" ]; then
        echo "not yet: $app was correct against 4s of lag and failed against 12s:"
        tail -3 /tmp/grader-checkout-12.log | sed 's/^/    /'
        echo "Whatever it waits for has to be the replica catching up to this write,"
        echo "not an amount of time that happened to be enough once."
        exit 1
      fi
      if [ "$delta12" -lt 1 ]; then
        echo "not yet: the 12s run never read orders on the replica."
        exit 1
      fi
      if [ $(( took12 - took4 )) -lt 4 ]; then
        echo "not yet: $app took ${took4}s against 4s of lag and ${took12}s against 12s."
        echo "It is waiting a fixed amount rather than waiting for this write to arrive,"
        echo "so it is only ever correct while lag stays under whatever that amount is."
        echo "The primary can say which WAL position this commit is at, and the replica"
        echo "can say which position it has replayed. Wait until the second passes the"
        echo "first."
        exit 1
      fi

      echo "PASS — the replica is replaying again, and the order page still reads from"
      echo "it while staying correct: ${took4}s against 4s of lag, ${took12}s against 12s."
