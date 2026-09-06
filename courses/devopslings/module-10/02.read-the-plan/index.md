---
kind: lesson
title: "one query, ten million rows, and a planner that guessed wrong"
description: |
  A report query takes seconds and nobody can say why. Read its plan properly:
  which scan it chose, how many rows it expected against how many it found, and
  the node where that estimate first went wrong — because every choice above
  that node was made on a bad number.
name: read-the-plan
slug: read-the-plan
createdAt: "2026-09-04"

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

      install -d /work
      rm -f /work/answers/plan.md
      install -d /work/answers

      # The query the report runs. The cast is the whole story: `reference` is
      # text, and comparing it as a number means the planner has no statistics
      # for what it is actually filtering on, so it falls back to a guess.
      #
      # Parallelism is turned off for this session on purpose. With workers the
      # scan node reports rows *per worker* alongside `loops=3`, and reading
      # that correctly is a later subject — here it would make "how many rows
      # did that node produce" have two defensible answers.
      cat > /work/report.sql <<'SQL'
      SET max_parallel_workers_per_gather = 0;

      SELECT count(*)
      FROM orders
      WHERE reference::bigint BETWEEN 10999000 AND 11000000;
      SQL

      cat > /work/answers/plan.md <<'MD'
      # Reading the plan

      # The scan type the plan chose for `orders`. One of:
      #   seq | index | index-only | bitmap
      scan: ?

      # Rows the planner ESTIMATED it would get from that scan node.
      estimated-rows: ?

      # Rows it ACTUALLY got from that node.
      actual-rows: ?

      # Where the estimate first went wrong, and why. Name the expression the
      # planner could not use statistics for.
      why: ?
      MD

      psql -c 'ANALYZE orders' >/dev/null

      echo "scenario ready"
      echo
      echo "  the query:   /work/report.sql"
      echo "  your answer: /work/answers/plan.md"
      echo
      echo "Run it, and then get the plan with real numbers in it:"
      echo
      echo "  export PGPASSWORD=devopslings"
      echo "  psql -h 127.0.0.1 -U postgres -d shop -f /work/report.sql"
      echo
      echo "  psql -h 127.0.0.1 -U postgres -d shop \\"
      echo "    -c 'SET max_parallel_workers_per_gather = 0' \\"
      echo "    -c 'EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM orders"
      echo "        WHERE reference::bigint BETWEEN 10999000 AND 11000000'"
      echo
      echo "EXPLAIN alone gives you the guess. ANALYZE runs it and gives you both."

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 900
    run: |
      export PGPASSWORD=devopslings
      psql() { command psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 "$@"; }
      ans=/work/answers/plan.md

      if [ ! -s "$ans" ]; then
        echo "not yet: $ans is missing or empty"
        exit 1
      fi
      if grep -q ': *?$' "$ans" 2>/dev/null; then
        echo "not yet: $ans still has unanswered '?' fields"
        exit 1
      fi

      field() {
        grep -E "^$1:" "$ans" 2>/dev/null | head -1 | sed "s/^$1: *//" | tr -d '\r' || true
      }

      # The grader takes the plan itself rather than trusting a number in a
      # file, so the answer is checked against this database as it is now. The
      # SET is applied in the same session rather than being read from the
      # file, so a student's plan and the grader's are the same shape.
      # Newlines become spaces rather than being deleted: stripping them
      # welds the last word of one line to the first of the next.
      query=$(grep -v '^ *SET ' /work/report.sql 2>/dev/null | tr -d ';' | tr '\n' ' ' || true)
      plan=$(psql -c 'SET max_parallel_workers_per_gather = 0' \
                  -c "EXPLAIN (ANALYZE, FORMAT JSON) ${query}" 2>/dev/null || true)
      if [ -z "$plan" ]; then
        echo "not yet: the grader could not run the report query. Is /work/report.sql"
        echo "still there and still valid SQL?"
        exit 1
      fi

      # The scan over `orders` is the deepest node naming that relation.
      node=$(printf '%s' "$plan" | tr ',' '\n' | grep -A0 '"Node Type"' | head -20 || true)
      real_scan=$(printf '%s' "$plan" | sed -n 's/.*"Node Type": "\([^"]*\)".*/\1/p' \
                    | grep -iE 'scan' | tail -1 || true)
      est=$(printf '%s' "$plan" | sed -n 's/.*"Plan Rows": \([0-9]*\).*/\1/p' | tail -1 || true)
      act=$(printf '%s' "$plan" | sed -n 's/.*"Actual Rows": \([0-9]*\).*/\1/p' | tail -1 || true)

      if [ -z "$real_scan" ] || [ -z "$est" ] || [ -z "$act" ]; then
        echo "not yet: the grader could not read a scan node out of the plan. Re-run"
        echo "'devopslings reset read-the-plan' and try again."
        exit 1
      fi

      want_scan=seq
      case "$real_scan" in
        *"Seq Scan"*)         want_scan=seq ;;
        *"Bitmap Heap Scan"*) want_scan=bitmap ;;
        *"Index Only Scan"*)  want_scan=index-only ;;
        *"Index Scan"*)       want_scan=index ;;
      esac

      got_scan=$(field scan | tr 'A-Z' 'a-z' | tr -d ' ')
      if [ "$got_scan" != "$want_scan" ]; then
        echo "not yet: you said the scan was '${got_scan:-nothing}'. The plan says"
        echo "'${real_scan}', which is '${want_scan}' in the words this exercise uses."
        echo "The scan type is the first line of the plan that matters: it says whether"
        echo "the database is reading the whole table or being pointed at rows."
        exit 1
      fi

      got_est=$(field estimated-rows | tr -cd '0-9')
      got_act=$(field actual-rows | tr -cd '0-9')
      if [ -z "$got_est" ] || [ -z "$got_act" ]; then
        echo "not yet: estimated-rows and actual-rows both have to be numbers."
        exit 1
      fi

      # Row counts move a little between runs, so the check is proportional
      # rather than exact — the point is reading the right pair of numbers off
      # the right node, not transcribing them to the digit.
      within() {
        _got=$1; _want=$2
        [ "$_want" -eq 0 ] && { [ "$_got" -eq 0 ]; return; }
        _lo=$(( _want / 2 )); _hi=$(( _want * 2 ))
        [ "$_got" -ge "$_lo" ] && [ "$_got" -le "$_hi" ]
      }

      if ! within "$got_est" "$est"; then
        echo "not yet: you gave the estimate as ${got_est}; the plan's scan node says"
        echo "${est}. That number is 'rows=' on the node itself, not the row count of"
        echo "the final result."
        exit 1
      fi
      if ! within "$got_act" "$act"; then
        echo "not yet: you gave the actual count as ${got_act}; the plan says ${act}."
        echo "'actual rows=' only appears when you ask for ANALYZE — EXPLAIN on its own"
        echo "prints the guess and nothing to compare it against."
        exit 1
      fi

      why=$(field why)
      why_len=$(printf '%s' "$why" | tr -d '[:space:]' | wc -c | tr -d ' ')
      if [ "${why_len:-0}" -lt 60 ]; then
        echo "not yet: 'why:' is missing or too short. The planner keeps statistics"
        echo "about the values in a column. Say what the query does to 'reference' that"
        echo "puts the thing being filtered beyond the reach of those statistics."
        exit 1
      fi
      case "$(printf '%s' "$why" | tr 'A-Z' 'a-z')" in
        *cast*|*bigint*|*type*|*conver*|*expression*) ;;
        *)
          echo "not yet: 'why:' does not mention what happens to the column. The filter"
          echo "is not on 'reference' — it is on an expression computed from it, and"
          echo "there are no statistics for that expression."
          exit 1
          ;;
      esac

      echo "PASS — scan '${real_scan}', estimated ${est} rows against ${act} actual, and"
      echo "the reason named."
---
