---
kind: lesson
title: "the index exists and the planner will not touch it"
description: |
  Two queries, two indexes on exactly the columns they filter, two sequential
  scans. Neither index is broken and neither needs rebuilding: the queries do
  not filter on the columns, they filter on expressions computed from them, and
  an index on a column does not cover a function of that column.
name: the-index-that-is-not-used
slug: the-index-that-is-not-used
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

      install -d /work/queries /work/answers
      rm -f /work/answers/indexes.md

      # Reset drops whatever indexes a previous attempt left behind, so the
      # scenario starts broken every time. The keep-list is the seeded schema
      # plus the email index this lesson relies on being present and useless.
      psql <<'SQL' >/dev/null
      SET client_min_messages = warning;

      DO $$
      DECLARE i text;
      BEGIN
        FOR i IN
          SELECT indexname FROM pg_indexes
          WHERE schemaname = 'public'
            AND tablename IN ('orders', 'customers')
            AND indexname NOT IN ('orders_pkey', 'customers_pkey',
                                  'orders_customer_id_idx', 'orders_placed_at_idx',
                                  'orders_reference_idx', 'customers_email_idx')
        LOOP
          EXECUTE format('DROP INDEX IF EXISTS public.%I', i);
        END LOOP;
      END $$;

      CREATE INDEX IF NOT EXISTS customers_email_idx ON customers (email);

      -- One address stored with capitals in it. That is why the sign-in query
      -- wraps the column in lower() at all, and it is what stops "delete the
      -- lower() call" from being a fix: without it the row is not found.
      UPDATE customers SET email = 'Customer137@Example.invalid' WHERE id = 137;
      SQL

      cat > /work/queries/lookup.sql <<'SQL'
      SELECT id, customer_id, status, total_cents
      FROM orders
      WHERE reference::bigint = 10500000;
      SQL

      cat > /work/queries/signin.sql <<'SQL'
      SELECT id, country
      FROM customers
      WHERE lower(email) = 'customer137@example.invalid';
      SQL

      cat > /work/answers/indexes.md <<'MD'
      # Two indexes the planner will not use

      # Why does lookup.sql not use orders_reference_idx? Name what the query
      # does to the column.
      lookup-cause: ?

      # Why does signin.sql not use customers_email_idx?
      signin-cause: ?
      MD

      psql -c 'ANALYZE orders' -c 'ANALYZE customers' >/dev/null

      echo "scenario ready"
      echo
      echo "  the queries: /work/queries/lookup.sql, /work/queries/signin.sql"
      echo "  your answer: /work/answers/indexes.md"
      echo
      echo "  export PGPASSWORD=devopslings"
      echo "  psql -h 127.0.0.1 -U postgres -d shop -f /work/queries/lookup.sql"
      echo
      echo "Both queries have an index on the column in their WHERE clause."
      echo "Both do a sequential scan anyway. Find out why before you change"
      echo "anything: \\d orders and \\d customers list the indexes, and"
      echo "EXPLAIN (ANALYZE) tells you what the planner did with them."

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 900
    run: |
      export PGPASSWORD=devopslings
      psql() { command psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 "$@"; }
      ans=/work/answers/indexes.md

      # The orders query is the one with a meaningful clock on it: a sequential
      # scan of ten million rows is around a second warm and several cold, and
      # an index lookup of one row is under a millisecond. The budget sits far
      # from both, so it measures the plan and not the machine.
      budget_ms=250

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

      # Newlines become spaces rather than being deleted: stripping them welds
      # the last word of one line to the first of the next.
      read_query() {
        grep -v '^ *SET ' "$1" 2>/dev/null | tr -d ';' | tr '\n' ' ' || true
      }

      # Parallelism is off in the grader's session so that a parallel sequential
      # scan cannot come in under the budget and read as a fix. It is still a
      # sequential scan; it just has more cores.
      explain() {
        psql -c 'SET max_parallel_workers_per_gather = 0' \
             -c "EXPLAIN (ANALYZE) $1" 2>/dev/null || true
      }

      for f in /work/queries/lookup.sql /work/queries/signin.sql; do
        if [ ! -s "$f" ]; then
          echo "not yet: $f is missing or empty. Both queries have to still be there —"
          echo "the application runs them. Run 'devopslings reset the-index-that-is-not-used'"
          echo "to put them back."
          exit 1
        fi
      done

      lookup=$(read_query /work/queries/lookup.sql)
      signin=$(read_query /work/queries/signin.sql)

      lookup_plan=$(explain "$lookup")
      signin_plan=$(explain "$signin")
      if [ -z "$lookup_plan" ] || [ -z "$signin_plan" ]; then
        echo "not yet: the grader could not run one of the queries. Are both files in"
        echo "/work/queries still valid SQL?"
        exit 1
      fi

      # Results are compared against the answer this database holds, so a query
      # rewritten into something faster and wrong does not pass.
      want_lookup=$(psql -c "SELECT id, customer_id, status, total_cents FROM orders WHERE reference = '10500000' ORDER BY id" 2>/dev/null || true)
      want_signin=$(psql -c "SELECT id, country FROM customers WHERE lower(email) = 'customer137@example.invalid' ORDER BY id" 2>/dev/null || true)
      got_lookup=$(psql -c "$lookup" 2>/dev/null || true)
      got_signin=$(psql -c "$signin" 2>/dev/null || true)

      if [ "$got_lookup" != "$want_lookup" ]; then
        echo "not yet: lookup.sql no longer returns what it used to. It should still"
        echo "return the order whose reference is 10500000, with the same columns."
        echo "Expected:"
        printf '%s\n' "$want_lookup" | sed 's/^/  /'
        echo "Got:"
        printf '%s\n' "${got_lookup:-<nothing>}" | sed 's/^/  /'
        exit 1
      fi
      if [ "$got_signin" != "$want_signin" ]; then
        echo "not yet: signin.sql no longer returns what it used to. It should still"
        echo "find the customer whose address is customer137@example.invalid, with the"
        echo "same columns. That address is not stored the way it is typed — check how"
        echo "row 137 is actually spelled before deciding the lower() call is redundant."
        echo "Expected:"
        printf '%s\n' "$want_signin" | sed 's/^/  /'
        echo "Got:"
        printf '%s\n' "${got_signin:-<nothing>}" | sed 's/^/  /'
        exit 1
      fi

      if printf '%s' "$lookup_plan" | grep -q 'Seq Scan on orders'; then
        echo "not yet: lookup.sql still sequentially scans all ten million orders."
        echo "The plan says:"
        printf '%s\n' "$lookup_plan" | head -4 | sed 's/^/  /'
        echo "An index on reference cannot answer a predicate on an expression computed"
        echo "from reference. Either give the database an index on the expression the"
        echo "query actually filters by, or change the query to filter on the column as"
        echo "it is stored."
        exit 1
      fi
      if printf '%s' "$signin_plan" | grep -q 'Seq Scan on customers'; then
        echo "not yet: signin.sql still sequentially scans customers. The plan says:"
        printf '%s\n' "$signin_plan" | head -4 | sed 's/^/  /'
        echo "customers_email_idx indexes email as stored. The query filters on"
        echo "lower(email), which is a different value, and one this table has no index"
        echo "on. Deleting the lower() call is not the way out either: look at how row"
        echo "137 is actually spelled, and at what the query would then stop finding."
        exit 1
      fi

      took=$(printf '%s' "$lookup_plan" | sed -n 's/.*Execution Time: \([0-9.]*\) ms.*/\1/p' | tail -1 || true)
      if [ -z "$took" ]; then
        echo "not yet: the grader could not read an execution time out of lookup.sql's"
        echo "plan. Re-run 'devopslings reset the-index-that-is-not-used'."
        exit 1
      fi
      if ! awk -v t="$took" -v b="$budget_ms" 'BEGIN { exit !(t <= b) }'; then
        echo "not yet: lookup.sql is not doing a sequential scan any more, but it took"
        echo "${took}ms against a budget of ${budget_ms}ms. Look at the plan and at how"
        echo "many rows the scan node actually returns — an index that matches a large"
        echo "part of the table costs more than reading the table."
        printf '%s\n' "$lookup_plan" | head -4 | sed 's/^/  /'
        exit 1
      fi

      cause() {
        _got=$(field "$1" | tr 'A-Z' 'a-z')
        _len=$(printf '%s' "$_got" | tr -d '[:space:]' | wc -c | tr -d ' ')
        if [ "${_len:-0}" -lt 50 ]; then
          echo "not yet: '$1:' is missing or too short to be an answer. Say what the"
          echo "query does to the column that puts the value being filtered outside"
          echo "what the index on that column contains."
          return 1
        fi
        # Word boundaries, not substrings: "slower" contains "lower", and
        # "the planner thought the index would be slower" is exactly the wrong
        # answer this check exists to reject.
        if ! printf '%s' "$_got" | grep -Eq '\b(cast|casts|casting|bigint|convert|converts|converted|conversion|expression|expressions|function|functions|lower|lowercase|lowercased|type|types)\b'; then
          echo "not yet: '$1:' does not name what happens to the column. The index"
          echo "holds the column's stored values. The WHERE clause compares something"
          echo "computed from it. Name that computation."
          return 1
        fi
      }

      cause lookup-cause || exit 1
      cause signin-cause || exit 1

      echo "PASS — both queries use an index, both still return the right rows, and"
      echo "lookup.sql came back in ${took}ms against a ${budget_ms}ms budget."
---
