#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Two separate things have to be true. The tables must belong to somebody other
# than the application, because an owner can always drop what it owns however
# much has been revoked. And the application must be granted the four verbs it
# actually uses, on the objects it actually touches, rather than everything.
set -euo pipefail

export PGPASSWORD=devopslings
psql() { command psql -q -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 "$@"; }

psql <<'SQL'
-- Ownership moves back to postgres. This alone stops DROP.
ALTER TABLE orders    OWNER TO postgres;
ALTER TABLE customers OWNER TO postgres;
ALTER SEQUENCE orders_id_seq    OWNER TO postgres;
ALTER SEQUENCE customers_id_seq OWNER TO postgres;

-- Start from nothing rather than trying to subtract from ALL.
REVOKE ALL ON SCHEMA public FROM app;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM app;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM app;

-- USAGE lets the role see the schema; it does not let it create in it.
GRANT USAGE ON SCHEMA public TO app;

GRANT SELECT, INSERT, UPDATE, DELETE ON orders, customers TO app;

-- INSERT needs the sequence behind the bigserial primary key.
GRANT USAGE, SELECT ON SEQUENCE orders_id_seq, customers_id_seq TO app;
SQL

echo "app: read/write on orders and customers, owner of nothing"
