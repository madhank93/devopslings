---
kind: lesson
title: "the page takes five seconds and nothing in the log is slow"
description: |
  A page renders two hundred orders in five seconds. Every statement behind it
  finishes in well under a millisecond, so sorting the slow-query log by
  duration finds nothing at all. The cost is not in any one query — it is in
  how many there are, which is a column you have to go looking for.
name: n-plus-one
slug: n-plus-one
createdAt: "2026-09-06"

sandbox:
  stack: db-stack
  service: primary

tasks:
  init_scenario:
    init: true
    timeout_seconds: 900
    run: |
      export PGPASSWORD=devopslings
      psql() { command psql -q -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 "$@"; }

      install -d /work/app /work/answers
      rm -f /work/answers/n-plus-one.md

      cat > /work/app/page.sh <<'SH'
      #!/usr/bin/env bash
      # Renders the "recent orders" page: the two hundred newest orders, each
      # with the email address of the customer who placed it.
      set -euo pipefail

      export PGPASSWORD=devopslings
      q() { psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 -c "$1"; }

      rows=$(q "SELECT id, customer_id, total_cents FROM orders ORDER BY id DESC LIMIT 200")

      while IFS='|' read -r id customer_id total; do
        email=$(q "SELECT email FROM customers WHERE id = $customer_id")
        printf '%s|%s|%s\n' "$id" "$email" "$total"
      done <<< "$rows"
      SH
      chmod +x /work/app/page.sh

      cat > /work/answers/n-plus-one.md <<'MD'
      # The page nobody can find in the slow-query log

      # The statement the page runs too many times, written the way
      # pg_stat_statements records it — with its literals replaced by $1.
      statement: ?

      # How many times ONE render of the page runs that statement.
      calls-per-render: ?
      MD

      # A clean slate to read. The seed's foreign-key checks alone are ten
      # million calls, and they would sit at the top of every count.
      psql -c 'SELECT pg_stat_statements_reset()' >/dev/null

      echo "scenario ready"
      echo
      echo "  the page:    /work/app/page.sh"
      echo "  your answer: /work/answers/n-plus-one.md"
      echo
      echo "  time bash /work/app/page.sh"
      echo
      echo "Nothing this page runs is slow. pg_stat_statements has just been"
      echo "reset, so whatever is in it after a render is the page's own work:"
      echo
      echo "  export PGPASSWORD=devopslings"
      echo "  psql -h 127.0.0.1 -U postgres -d shop -c \\"
      echo "    'SELECT calls, round(mean_exec_time::numeric, 3) AS ms, query"
      echo "       FROM pg_stat_statements ORDER BY calls DESC LIMIT 5'"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 900
    run: |
      export PGPASSWORD=devopslings
      psql() { command psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 "$@"; }
      ans=/work/answers/n-plus-one.md
      page=/work/app/page.sh

      # Five seconds of round trips against thirty milliseconds of query. The
      # budget sits far from both, so it measures the number of round trips and
      # not the machine.
      budget_ms=500
      # One statement is the fix; a preload into WHERE id = ANY(...) is two.
      # The floor is what stops a page that answers from a cached file.
      max_statements=5

      if [ ! -s "$ans" ]; then
        echo "not yet: $ans is missing or empty"
        exit 1
      fi
      if grep -q ': *?$' "$ans" 2>/dev/null; then
        echo "not yet: $ans still has unanswered '?' fields"
        exit 1
      fi
      if [ ! -s "$page" ]; then
        echo "not yet: $page is missing or empty. The page still has to render."
        echo "Run 'devopslings reset n-plus-one' to put it back."
        exit 1
      fi

      field() {
        grep -E "^$1:" "$ans" 2>/dev/null | head -1 | sed "s/^$1: *//" | tr -d '\r' || true
      }

      # pg_stat_statements accumulates, so the page's statement count is the
      # difference across a render rather than a reset — resetting here would
      # destroy the evidence a student has not finished reading yet. The
      # snapshot query is itself a statement and is recorded before the second
      # snapshot reads the total, so the delta is always one too high.
      before=$(psql -c 'SELECT sum(calls) FROM pg_stat_statements' 2>/dev/null || true)
      started=$(date +%s%N)
      out=$(bash "$page" 2>/dev/null || true)
      elapsed_ms=$(( ( $(date +%s%N) - started ) / 1000000 ))
      after=$(psql -c 'SELECT sum(calls) FROM pg_stat_statements' 2>/dev/null || true)

      if [ -z "$out" ]; then
        echo "not yet: the page printed nothing. Run it yourself and see what it says:"
        echo
        echo "  bash $page"
        exit 1
      fi

      want=$(psql -c "SELECT o.id, c.email, o.total_cents FROM orders o
                        JOIN customers c ON c.id = o.customer_id
                       ORDER BY o.id DESC LIMIT 200" 2>/dev/null || true)
      if [ "$out" != "$want" ]; then
        echo "not yet: the page no longer renders what it used to. It is still the two"
        echo "hundred newest orders, newest first, as id|email|total_cents."
        echo "Expected $(printf '%s\n' "$want" | wc -l | tr -d ' ') lines starting:"
        printf '%s\n' "$want" | head -2 | sed 's/^/  /'
        echo "Got $(printf '%s\n' "$out" | wc -l | tr -d ' ') lines starting:"
        printf '%s\n' "$out" | head -2 | sed 's/^/  /'
        exit 1
      fi

      if [ -z "$before" ] || [ -z "$after" ]; then
        echo "not yet: the grader could not read pg_stat_statements. Is the extension"
        echo "still installed? 'devopslings reset n-plus-one' rebuilds the scenario."
        exit 1
      fi
      statements=$(( after - before - 1 ))

      if [ "$statements" -lt 1 ]; then
        echo "not yet: rendering the page ran no queries at all. It has to read the"
        echo "orders out of the database each time, not replay something it saved"
        echo "earlier — a page that cannot see a new order is not a faster page."
        exit 1
      fi
      if [ "$statements" -gt "$max_statements" ]; then
        echo "not yet: one render still issues ${statements} statements. Two hundred of"
        echo "them are the same lookup with a different id, and the database is not"
        echo "what is slow — each one costs a round trip, and the page pays two"
        echo "hundred of them in a row. Ask for the customers in the same statement"
        echo "that asks for the orders, or in one more statement that fetches all of"
        echo "them at once."
        exit 1
      fi
      if [ "$elapsed_ms" -gt "$budget_ms" ]; then
        echo "not yet: the page issues only ${statements} statements now but took"
        echo "${elapsed_ms}ms against a budget of ${budget_ms}ms. Check the plan of what"
        echo "it runs — a join that reads more of the table than the page shows costs"
        echo "more than the round trips did."
        exit 1
      fi

      got_stmt=$(field statement | tr 'A-Z' 'a-z')
      case "$got_stmt" in
        *customers*) ;;
        *)
          echo "not yet: 'statement:' does not name a lookup against customers. The"
          echo "expensive statement is not the slow one — order pg_stat_statements by"
          echo "'calls' rather than by time and read the top row."
          exit 1
          ;;
      esac
      case "$got_stmt" in
        *'$1'*) ;;
        *)
          echo "not yet: 'statement:' has no \$1 in it. pg_stat_statements does not store"
          echo "two hundred statements that differ by an id — it replaces the literals"
          echo "with placeholders and counts them as one. Paste the text it recorded."
          exit 1
          ;;
      esac

      got_calls=$(field calls-per-render | tr -cd '0-9')
      if [ "$got_calls" != "200" ]; then
        echo "not yet: 'calls-per-render:' says '${got_calls:-nothing}'. The page shows"
        echo "two hundred orders and looks each customer up separately, so one render"
        echo "is two hundred calls of that one statement. If the number you read was"
        echo "larger, remember that pg_stat_statements adds up every render since the"
        echo "last reset — divide by how many times you ran the page."
        exit 1
      fi

      echo "PASS — the page renders in ${elapsed_ms}ms with ${statements} statement(s)"
      echo "instead of 201, and the query that was invisible in the slow log is named."
---
