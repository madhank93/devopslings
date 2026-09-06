#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Both queries are left exactly as the application wrote them. The fix is to
# index the expression each one actually filters on, rather than the column it
# appears to.
set -euo pipefail

export PGPASSWORD=devopslings
psql() { command psql -q -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 "$@"; }

psql -c 'CREATE INDEX orders_reference_bigint_idx ON orders (((reference)::bigint))'
psql -c 'CREATE INDEX customers_email_lower_idx ON customers (lower(email))'

# An expression index gets its own statistics, and only ANALYZE collects them.
psql -c 'ANALYZE orders' -c 'ANALYZE customers'

install -d /work/answers
cat > /work/answers/indexes.md <<'MD'
# Two indexes the planner will not use

# Why does lookup.sql not use orders_reference_idx? Name what the query
# does to the column.
lookup-cause: reference is stored as text and the query compares it to a number, so Postgres casts the column with reference::bigint. The index holds the text values; the predicate is on an expression computed from them, and a btree index can only answer a predicate on the thing it actually stores. Indexing the expression itself, or comparing to the text value '10500000' instead, both give the planner something the index covers.

# Why does signin.sql not use customers_email_idx?
signin-cause: customers_email_idx contains email as stored, capitals and all, while the query filters on lower(email) — a function wrapped around the column, which is a different value the index knows nothing about. Row 137 is stored as Customer137@Example.invalid, so removing the lower() call would lose the row; the fix is an index on lower(email).
MD

echo "expression indexes created, answers written"
