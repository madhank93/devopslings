#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The shard key becomes tenant + customer instead of tenant alone: the big
# tenant's eight hundred customers land on four shards instead of one, and a
# customer is still whole on a single shard, so the read the application does
# most still has one place to go.
set -euo pipefail
export PGPASSWORD=devopslings
P() { psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 "$@"; }

cat > /work/app/router.sql <<'ROUTER'
-- The router. Every write and every read goes through this: the application
-- asks it which shard a row lives on, then talks to that shard and no other.
--
-- Keyed on tenant and customer together. Tenant alone put one tenant's whole
-- workload on one shard, and no number of shards divides one hash value.
-- Customer is the narrowest unit the common read never crosses, so hashing it
-- spreads the writes without turning that read into four.
CREATE OR REPLACE FUNCTION shard_for(p_tenant int, p_customer int, p_order bigint)
RETURNS int LANGUAGE sql IMMUTABLE AS $fn$
  SELECT ((hashtextextended(p_tenant::text || ':' || p_customer::text, 0) % 4 + 4) % 4)::int
$fn$;
ROUTER

P -f /work/app/router.sql >/dev/null

# Move the rows that are already there to where the new router looks for them.
# One transaction: a reader that arrives mid-rebalance sees the old placement
# or the new one, never half of each.
P >/dev/null <<'SQL'
BEGIN;
CREATE TEMP TABLE rebalance AS
  SELECT * FROM shard_0 UNION ALL SELECT * FROM shard_1 UNION ALL
  SELECT * FROM shard_2 UNION ALL SELECT * FROM shard_3;
TRUNCATE shard_0, shard_1, shard_2, shard_3;
INSERT INTO shard_0 SELECT * FROM rebalance WHERE shard_for(tenant_id, customer_id, order_id) = 0;
INSERT INTO shard_1 SELECT * FROM rebalance WHERE shard_for(tenant_id, customer_id, order_id) = 1;
INSERT INTO shard_2 SELECT * FROM rebalance WHERE shard_for(tenant_id, customer_id, order_id) = 2;
INSERT INTO shard_3 SELECT * FROM rebalance WHERE shard_for(tenant_id, customer_id, order_id) = 3;
COMMIT;
SQL
P -c "ANALYZE shard_0, shard_1, shard_2, shard_3" >/dev/null

install -d /work/answers
cat > /work/answers/sharding.md <<'MD'
# The hot shard

# One line: what about the shard key put most of the orders on one shard?
what-the-key-did: it hashed the tenant id alone, and tenant 42 places seven orders in ten, so that one tenant's whole workload resolves to one hash value and lands on one shard

# The plan on the whiteboard is a fifth shard. One line: what happens to
# the busiest shard's share of the writes when you add one?
why-a-fifth-shard-does-not-help: nothing useful — rehashing moves tenants between shards but tenant 42 is still a single key that cannot be split, so whichever shard it lands on still takes 70% of the writes

# Hashing the order id would spread the writes perfectly across all four
# shards. One line: what would that cost the read the application does
# most — this customer's recent orders?
cost-of-a-perfect-spread: every customer's orders would be scattered over all four shards, so the read becomes a scatter-gather — four queries and a merge — and its latency becomes the slowest shard's
MD

echo "router rekeyed on tenant+customer, 400000 orders rebalanced"
