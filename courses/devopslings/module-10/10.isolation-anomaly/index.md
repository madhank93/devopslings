---
kind: lesson
title: "eight refunds went through and the order is down by one of them"
description: |
  The adjuster reads the order total, works out the new figure, and writes it
  back — all inside one transaction, which is the first thing anybody checks.
  Run eight of them at once and seven of the eight deductions are simply not
  there afterwards. No error, no rollback, no deadlock. Every transaction
  committed and every one of them was right about what it read.
name: isolation-anomaly
slug: isolation-anomaly
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
      rm -f /work/answers/isolation.md

      P >/dev/null <<'SQL'
      DELETE FROM orders WHERE reference LIKE 'ADJ-%';
      INSERT INTO orders (customer_id, status, reference, total_cents, placed_at)
      VALUES (1, 'disputed', 'ADJ-1', 100000, now());
      SQL

      cat > /work/app/adjust.sh <<'SH'
      #!/usr/bin/env bash
      # One adjustment against the order under dispute.
      #
      # Read the current total, work out the new figure, write it back. The
      # read and the write are in the same transaction, which is where
      # everybody stops looking.
      set -euo pipefail
      export PGPASSWORD=devopslings
      amount=${1:-500}
      ref=${2:-ADJ-1}

      psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 >/dev/null <<SQL
      BEGIN;
      SELECT total_cents AS t FROM orders WHERE reference = '$ref' \gset
      -- Working the new figure out: fees, tax, the partial-refund rules.
      -- Stubbed, and it is why two adjusters are ever in here at once.
      SELECT pg_sleep(0.2);
      UPDATE orders SET total_cents = :t - $amount WHERE reference = '$ref';
      COMMIT;
      SQL
      SH
      chmod +x /work/app/adjust.sh

      cat > /work/app/adjust-many.sh <<'SH'
      #!/usr/bin/env bash
      # Fire N adjusters at the same order at once, and report what landed.
      # This is the instrument, not the thing under repair.
      set -euo pipefail
      export PGPASSWORD=devopslings
      n=${1:-8}
      amount=${2:-500}
      P() { psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 "$@"; }

      before=$(P -c "SELECT total_cents FROM orders WHERE reference = 'ADJ-1'")
      pids=""
      start=$(date +%s%N)
      for i in $(seq 1 "$n"); do
        bash /work/app/adjust.sh "$amount" & pids="$pids $!"
      done
      failed=0
      for p in $pids; do wait "$p" || failed=$(( failed + 1 )); done
      ms=$(( ($(date +%s%N) - start) / 1000000 ))
      after=$(P -c "SELECT total_cents FROM orders WHERE reference = 'ADJ-1'")

      echo "$n adjusters of -$amount in ${ms}ms, $failed failed"
      echo "  total $before -> $after, expected $(( before - n * amount ))"
      SH
      chmod +x /work/app/adjust-many.sh

      cat > /work/answers/isolation.md <<'MD'
      # Eight refunds, one deduction

      # The isolation level the adjuster was running under while the
      # deductions were going missing. It is Postgres's default; name it.
      isolation-level: ?

      # What you changed so that two adjusters cannot both act on the same
      # figure. Say which of the two shapes it is: one that makes the second
      # transaction wait, or one that makes it fail and run again.
      what-you-chose: ?

      # Run eight adjusters at once and time it, before and after. One line:
      # what does the fix you chose cost as contention rises, and why?
      the-cost: ?
      MD

      echo "scenario ready — ADJ-1 is at $(P -c "SELECT total_cents FROM orders WHERE reference = 'ADJ-1'") cents"
      echo
      echo "  one adjustment:   /work/app/adjust.sh 500"
      echo "  eight at once:    /work/app/adjust-many.sh 8"
      echo "  your answer:      /work/answers/isolation.md"
      echo
      echo "  psql -h 127.0.0.1 -U postgres -d shop"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 600
    run: |
      export PGPASSWORD=devopslings
      P() { command psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 "$@"; }
      ans=/work/answers/isolation.md
      app=/work/app/adjust.sh

      if [ ! -s "$ans" ]; then
        echo "not yet: $ans is missing or empty"
        exit 1
      fi
      if grep -q ': *?$' "$ans" 2>/dev/null; then
        echo "not yet: $ans still has unanswered '?' fields"
        exit 1
      fi
      if [ ! -s "$app" ]; then
        echo "not yet: $app is missing or empty. The adjuster still has to run."
        echo "Run 'devopslings reset isolation-anomaly' to put the scenario back."
        exit 1
      fi

      field() {
        grep -E "^$1:" "$ans" 2>/dev/null | head -1 | sed "s/^$1: *//" | tr -d '\r' || true
      }
      total() { P -c "SELECT total_cents FROM orders WHERE reference = 'ADJ-1'"; }

      # --- one adjuster on its own has to still work --------------------------
      P -c "UPDATE orders SET total_cents = 100000 WHERE reference = 'ADJ-1'" >/dev/null
      rc=0
      timeout 120 bash "$app" 500 >/tmp/grader-solo.log 2>&1 || rc=$?
      solo=$(total)
      if [ "$rc" != "0" ]; then
        echo "not yet: one adjuster on its own, with nothing to contend with, failed:"
        tail -3 /tmp/grader-solo.log | sed 's/^/    /'
        exit 1
      fi
      if [ "${solo:-0}" != "99500" ]; then
        echo "not yet: one adjuster of -500 took 100000 to ${solo:-nothing}, not 99500. The"
        echo "adjustment still has to be the adjustment — a fix that changes what the job"
        echo "does to the money is not a fix."
        exit 1
      fi

      # --- and eight of them have to add up ------------------------------------
      workers=8
      amount=500
      slowest=0
      for round in 1 2 3; do
        P -c "UPDATE orders SET total_cents = 100000 WHERE reference = 'ADJ-1'" >/dev/null
        pids=""
        started=$(date +%s%N)
        for i in $(seq 1 $workers); do
          timeout 120 bash "$app" "$amount" >/tmp/grader-w$i.log 2>&1 & pids="$pids $!"
        done
        failed=0
        for p in $pids; do wait "$p" || failed=$(( failed + 1 )); done
        took=$(( ($(date +%s%N) - started) / 1000000 ))
        if [ "$took" -gt "$slowest" ]; then slowest=$took; fi
        got=$(total)
        want=$(( 100000 - workers * amount ))

        if [ "$failed" -gt 0 ]; then
          echo "not yet: round $round ran $workers adjusters at once and $failed of them exited"
          echo "non-zero:"
          echo
          { grep -hiE 'ERROR' /tmp/grader-w*.log 2>/dev/null || true; } | sort -u | head -3 | sed 's/^/    /'
          echo
          echo "An adjuster that gives up has not applied its adjustment. If the fix you chose"
          echo "makes the losing transaction fail rather than wait, then running it again is"
          echo "part of the fix and not an optional extra — the job has to end with the money"
          echo "moved."
          exit 1
        fi
        if [ "${got:-0}" != "$want" ]; then
          missing=$(( (got - want) / amount ))
          echo "not yet: round $round applied $workers adjustments of -$amount to a total of"
          echo "100000 and left it at ${got}, not ${want}. ${missing} of the eight are simply not"
          echo "there, and every one of those transactions committed without an error."
          echo
          echo "Each adjuster read the total, held it while it worked the new figure out, and"
          echo "wrote that figure back. Ask what the others had done to the row in between,"
          echo "and whether anything in the transaction was ever going to notice."
          exit 1
        fi
      done

      # --- the answers --------------------------------------------------------
      level=$(field isolation-level | tr 'A-Z' 'a-z')
      case "$level" in
        *read*committed*) ;;
        *repeatable*|*serializ*|*read*uncommitted*)
          echo "not yet: 'isolation-level:' says '$(field isolation-level)'. That may well be"
          echo "what you moved it to. The field is asking what it was while the deductions"
          echo "were disappearing — 'SHOW default_transaction_isolation' on a session that has"
          echo "not been told otherwise."
          exit 1
          ;;
        *)
          echo "not yet: 'isolation-level:' says '${level:-nothing}'. Postgres has a default"
          echo "that nearly nothing overrides, and under it every statement gets a fresh view"
          echo "of committed data — which is exactly why a value read at the start of the"
          echo "transaction is stale by the time it is written back. Name that level."
          exit 1
          ;;
      esac

      chose=$(field what-you-chose | tr 'A-Z' 'a-z')
      if ! printf '%s' "$chose" | grep -Eq '\b(for update|lock|locks|locked|locking|wait|waits|block|blocks|queue|queues|retry|retries|retried|again|abort|aborts|rollback|serializable|serialization|repeatable|atomic|atomically|in place)\b'; then
        echo "not yet: 'what-you-chose:' does not say which mechanism you used. There are"
        echo "three honest answers — take the row lock at read time so the next adjuster"
        echo "waits, raise the isolation level so it is refused and run it again, or stop"
        echo "reading the figure out to the client at all and let the UPDATE do the"
        echo "arithmetic. Say which, and which of the two shapes it is."
        exit 1
      fi

      cost=$(field the-cost | tr 'A-Z' 'a-z')
      if ! printf '%s' "$cost" | grep -Eq '[0-9]'; then
        echo "not yet: 'the-cost:' has no number in it. Time '/work/app/adjust-many.sh 8'"
        echo "and put the figure in — the question is what the fix costs, and a cost with no"
        echo "measurement behind it is a guess."
        exit 1
      fi
      if ! printf '%s' "$cost" | grep -Eq '\b(wait|waits|waiting|queue|queues|queued|serial|serially|serialise|serialize|serialized|block|blocks|blocked|lock|locks|retry|retries|retried|restart|restarts|abort|aborts|contention|contended|linear|grows|rises)\b'; then
        echo "not yet: 'the-cost:' gives a number but not what is being paid for. Under"
        echo "contention one shape queues the adjusters up behind each other and the other"
        echo "throws work away and repeats it. Say which one yours does."
        exit 1
      fi

      echo "PASS — eight concurrent adjusters, three rounds, every deduction landed"
      echo "(slowest round ${slowest}ms)."
