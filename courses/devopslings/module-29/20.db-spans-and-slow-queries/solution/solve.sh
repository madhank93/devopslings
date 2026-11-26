#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The slowest CLIENT spans carry db.query.text for the email lookup: customers
# has no index on email, so every call scans 200,000 rows. Its pg_stat_statements
# row has the same text with $1; an index makes the span sub-millisecond.
set -euo pipefail
python3 - <<'PY'
import psycopg
with psycopg.connect("host=pg dbname=shop user=postgres password=devopslings", autocommit=True) as c:
    c.execute("CREATE INDEX IF NOT EXISTS customers_email_idx ON customers (email)")
    qid = c.execute("SELECT queryid FROM pg_stat_statements WHERE query = 'SELECT id FROM customers WHERE email = $1'").fetchone()[0]
open("/obs/answers/slow-query.txt", "w").write(
    f"query: SELECT id FROM customers WHERE email = %(email)s\nqueryid: {qid}\n")
PY
sleep 25
