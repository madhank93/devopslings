---
kind: lesson
title: "four shards, and one of them is doing all the work"
description: |
  The orders table was split across four shards a year ago and it worked. Now
  one of them is at 80% CPU while the other three idle, the pager goes off every
  evening, and the plan on the whiteboard is a fifth shard. The fifth shard will
  not help, and the reason is one line of the router.
name: hot-shard
slug: hot-shard
createdAt: "2026-09-24"

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

      install -d /work/app /work/answers
      rm -f /work/answers/sharding.md

      cat > /work/app/router.sql <<'ROUTER'
      -- The router. Every write and every read goes through this: the
      -- application asks it which shard a row lives on, then talks to that
      -- shard and no other.
      --
      -- Keep the name and the signature. The application calls it with all
      -- three parts of the key and expects a shard number from 0 to 3.
      CREATE OR REPLACE FUNCTION shard_for(p_tenant int, p_customer int, p_order bigint)
      RETURNS int LANGUAGE sql IMMUTABLE AS $fn$
        SELECT ((hashtextextended(p_tenant::text, 0) % 4 + 4) % 4)::int
      $fn$;
      ROUTER

      P >/dev/null <<'SQL'
      DROP VIEW IF EXISTS all_orders;
      DROP TABLE IF EXISTS shard_0, shard_1, shard_2, shard_3, order_seed;
      SQL

      P -f /work/app/router.sql >/dev/null

      P >/dev/null <<'SQL'
      CREATE TABLE order_seed AS
      SELECT g AS order_id,
             t.tenant_id,
             1 + (g % CASE WHEN t.tenant_id = 42 THEN 800 ELSE 60 END) AS customer_id,
             now() - (g % 2000) * interval '1 minute' AS placed_at,
             (500 + (g % 40000))::bigint AS amount_cents
      FROM generate_series(1, 400000) g,
           LATERAL (SELECT CASE WHEN g % 10 < 7 THEN 42 ELSE 1 + (g % 11) END AS tenant_id) t;

      CREATE TABLE shard_0 (
          order_id     bigint PRIMARY KEY,
          tenant_id    int NOT NULL,
          customer_id  int NOT NULL,
          placed_at    timestamptz NOT NULL,
          amount_cents bigint NOT NULL
      );
      CREATE TABLE shard_1 (LIKE shard_0 INCLUDING ALL);
      CREATE TABLE shard_2 (LIKE shard_0 INCLUDING ALL);
      CREATE TABLE shard_3 (LIKE shard_0 INCLUDING ALL);

      INSERT INTO shard_0 SELECT * FROM order_seed WHERE shard_for(tenant_id, customer_id, order_id) = 0;
      INSERT INTO shard_1 SELECT * FROM order_seed WHERE shard_for(tenant_id, customer_id, order_id) = 1;
      INSERT INTO shard_2 SELECT * FROM order_seed WHERE shard_for(tenant_id, customer_id, order_id) = 2;
      INSERT INTO shard_3 SELECT * FROM order_seed WHERE shard_for(tenant_id, customer_id, order_id) = 3;

      CREATE INDEX ON shard_0 (tenant_id, customer_id, placed_at DESC);
      CREATE INDEX ON shard_1 (tenant_id, customer_id, placed_at DESC);
      CREATE INDEX ON shard_2 (tenant_id, customer_id, placed_at DESC);
      CREATE INDEX ON shard_3 (tenant_id, customer_id, placed_at DESC);

      DROP TABLE order_seed;

      CREATE VIEW all_orders AS
        SELECT 0 AS shard, * FROM shard_0 UNION ALL
        SELECT 1, * FROM shard_1 UNION ALL
        SELECT 2, * FROM shard_2 UNION ALL
        SELECT 3, * FROM shard_3;
      SQL
      P -c "ANALYZE shard_0, shard_1, shard_2, shard_3" >/dev/null

      cat > /work/answers/sharding.md <<'MD'
      # The hot shard

      # One line: what about the shard key put most of the orders on one shard?
      what-the-key-did: ?

      # The plan on the whiteboard is a fifth shard. One line: what happens to
      # the busiest shard's share of the writes when you add one?
      why-a-fifth-shard-does-not-help: ?

      # Hashing the order id would spread the writes perfectly across all four
      # shards. One line: what would that cost the read the application does
      # most — this customer's recent orders?
      cost-of-a-perfect-spread: ?
      MD

      echo "scenario ready"
      echo
      P -c "SELECT '  shard ' || shard || ': ' || lpad(count(*)::text, 6) || ' orders  ('
                   || round(100.0 * count(*) / sum(count(*)) OVER (), 1) || '%)'
              FROM all_orders GROUP BY shard ORDER BY shard"
      echo
      echo "  the router:   /work/app/router.sql"
      echo "  your answer:  /work/answers/sharding.md"
      echo
      echo "  psql -h 127.0.0.1 -U postgres -d shop"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 900
    run: |
      export PGPASSWORD=devopslings
      P() { command psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 "$@"; }
      ans=/work/answers/sharding.md

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

      # --- the pieces have to still be there ----------------------------------
      for k in 0 1 2 3; do
        if [ -z "$(P -c "SELECT to_regclass('shard_$k')")" ]; then
          echo "not yet: there is no shard_$k. The four shards are the machines you have;"
          echo "rebalancing means moving rows between them, not removing one."
          exit 1
        fi
      done
      if [ -z "$(P -c "SELECT to_regprocedure('shard_for(int,int,bigint)')")" ]; then
        echo "not yet: shard_for(int, int, bigint) is not defined. The application calls it"
        echo "with all three parts of the key and expects a shard number back, so the name"
        echo "and the signature have to survive whatever you do to the body."
        exit 1
      fi

      # --- nothing lost, nothing duplicated -----------------------------------
      total=$(P -c "SELECT (SELECT count(*) FROM shard_0) + (SELECT count(*) FROM shard_1)
                         + (SELECT count(*) FROM shard_2) + (SELECT count(*) FROM shard_3)")
      if [ "${total:-0}" != "400000" ]; then
        echo "not yet: the four shards hold ${total} orders between them and there were"
        echo "400000. A rebalance moves rows; it does not drop or invent them."
        exit 1
      fi
      distinct=$(P -c "SELECT count(*) FROM (
                         SELECT order_id FROM shard_0 UNION
                         SELECT order_id FROM shard_1 UNION
                         SELECT order_id FROM shard_2 UNION
                         SELECT order_id FROM shard_3) u")
      if [ "${distinct:-0}" != "400000" ]; then
        echo "not yet: the shards hold 400000 rows but only ${distinct} distinct order ids,"
        echo "so some order exists on two shards at once. Copy then delete leaves this if the"
        echo "delete is the part that did not finish."
        exit 1
      fi

      # --- every row where its own router says it lives -----------------------
      for k in 0 1 2 3; do
        bad=$(P -c "SELECT count(*) FROM shard_$k
                     WHERE shard_for(tenant_id, customer_id, order_id) IS DISTINCT FROM $k")
        if [ "${bad:-1}" != "0" ]; then
          echo "not yet: ${bad} rows on shard_$k are rows shard_for() does not send to shard_$k."
          echo "Reads go through the router, so a row the router cannot find is a row that is"
          echo "gone. Whichever you changed first — the placement or the function — the other"
          echo "one has to follow."
          exit 1
        fi
      done

      # --- the writes have to be spread ---------------------------------------
      maxpct=$(P -c "SELECT round(100.0 * max(c) / sum(c)) FROM (
                       SELECT count(*) c FROM shard_0 UNION ALL
                       SELECT count(*) FROM shard_1 UNION ALL
                       SELECT count(*) FROM shard_2 UNION ALL
                       SELECT count(*) FROM shard_3) x")
      if [ "${maxpct:-100}" -gt 35 ]; then
        echo "not yet: the busiest shard holds ${maxpct}% of the orders. Four shards, so an even"
        echo "split is 25% and the check allows up to 35%. Here is what is where:"
        echo
        P -c "SELECT '    shard ' || shard || ': ' || lpad(count(*)::text, 6) || '  ('
                     || round(100.0 * count(*) / sum(count(*)) OVER (), 1) || '%)'
                FROM (SELECT 0 AS shard, tenant_id, customer_id FROM shard_0 UNION ALL
                          SELECT 1, tenant_id, customer_id FROM shard_1 UNION ALL
                          SELECT 2, tenant_id, customer_id FROM shard_2 UNION ALL
                          SELECT 3, tenant_id, customer_id FROM shard_3) s GROUP BY shard ORDER BY shard"
        echo
        echo "Then ask what the busiest shard's rows have in common:"
        echo "    SELECT tenant_id, count(*) FROM shard_N GROUP BY 1 ORDER BY 2 DESC LIMIT 5;"
        exit 1
      fi

      # The same question about traffic that has not arrived yet: the next five
      # thousand orders, same tenant mix, routed by whatever shard_for() is now.
      nextpct=$(P -c "WITH nxt AS (
                        SELECT g AS order_id,
                               t.tenant_id,
                               1 + (g % CASE WHEN t.tenant_id = 42 THEN 800 ELSE 60 END) AS customer_id
                        FROM generate_series(400001, 405000) g,
                             LATERAL (SELECT CASE WHEN g % 10 < 7 THEN 42 ELSE 1 + (g % 11) END AS tenant_id) t)
                      SELECT round(100.0 * max(c) / sum(c)) FROM (
                        SELECT count(*) c FROM nxt
                         GROUP BY shard_for(tenant_id, customer_id, order_id)) x")
      if [ "${nextpct:-100}" -gt 35 ]; then
        echo "not yet: the rows that are already there are spread, and the next five thousand"
        echo "orders are not — ${nextpct}% of them route to one shard. Moving rows fixes the"
        echo "shard that is hot today. The router is what decides where tomorrow's writes go."
        exit 1
      fi

      # --- and the common read still has one place to go ----------------------
      scattered=$(P -c "WITH probe AS (
                          SELECT c.tenant_id, c.customer_id,
                                 shard_for(c.tenant_id, c.customer_id, o.oid) AS s
                          FROM (SELECT DISTINCT tenant_id, customer_id FROM (SELECT 0 AS shard, tenant_id, customer_id FROM shard_0 UNION ALL
                                     SELECT 1, tenant_id, customer_id FROM shard_1 UNION ALL
                                     SELECT 2, tenant_id, customer_id FROM shard_2 UNION ALL
                                     SELECT 3, tenant_id, customer_id FROM shard_3) u LIMIT 300) c,
                               LATERAL (SELECT unnest(ARRAY[1, 17, 4242, 123456, 9999999]::bigint[]) AS oid) o)
                        SELECT count(*) FROM (
                          SELECT tenant_id, customer_id FROM probe
                           GROUP BY 1, 2 HAVING count(DISTINCT s) > 1) x")
      if [ "${scattered:-1}" != "0" ]; then
        echo "not yet: for ${scattered} of the 300 customers probed, shard_for() answers"
        echo "differently depending on which order id it is given. That is a key that spreads"
        echo "writes by spreading each customer, so 'this customer's recent orders' has"
        echo "nowhere to go but all four shards — and the read the application does most just"
        echo "became four reads and a merge. Spread the writes without splitting a customer."
        exit 1
      fi
      split=$(P -c "SELECT count(*) FROM (
                      SELECT tenant_id, customer_id FROM (SELECT 0 AS shard, tenant_id, customer_id FROM shard_0 UNION ALL
                          SELECT 1, tenant_id, customer_id FROM shard_1 UNION ALL
                          SELECT 2, tenant_id, customer_id FROM shard_2 UNION ALL
                          SELECT 3, tenant_id, customer_id FROM shard_3) s
                       GROUP BY 1, 2 HAVING count(DISTINCT shard) > 1) x")
      if [ "${split:-1}" != "0" ]; then
        echo "not yet: ${split} customers have their orders on more than one shard, so the"
        echo "router agrees with itself and the data does not. Every row a customer owns has"
        echo "to sit on the shard the router names for that customer."
        exit 1
      fi

      # --- the answers --------------------------------------------------------
      did=$(field what-the-key-did | tr 'A-Z' 'a-z')
      if ! printf '%s' "$did" | grep -Eq '\b(tenant|tenants|42|customer|skew|skewed|dwarfs|biggest|largest)\b'; then
        echo "not yet: 'what-the-key-did:' does not name what the key was. The router hashed"
        echo "one column, and the orders are not spread evenly over the values of that column."
        echo "Find out which column and how lopsided it is:"
        echo "    SELECT tenant_id, count(*) FROM all_orders GROUP BY 1 ORDER BY 2 DESC LIMIT 5;"
        exit 1
      fi
      fifth=$(field why-a-fifth-shard-does-not-help | tr 'A-Z' 'a-z')
      if ! printf '%s' "$fifth" | grep -Eq '\b(still|same|unchanged|single|together|whole|indivisible|split|one (shard|value|key|hash|tenant))\b'; then
        echo "not yet: 'why-a-fifth-shard-does-not-help:' does not say what a fifth shard"
        echo "changes and what it does not. Adding one re-hashes every key and moves plenty of"
        echo "rows around. Say what it does to the rows that were all landing together, and"
        echo "why that is the part that matters."
        exit 1
      fi
      cost=$(field cost-of-a-perfect-spread | tr 'A-Z' 'a-z')
      if ! printf '%s' "$cost" | grep -Eq '(scatter|gather|fan-?out|broadcast|\b(every|all|four|4|each) shards?\b|\ball four\b|\bmerge\b)'; then
        echo "not yet: 'cost-of-a-perfect-spread:' does not say what the read costs when a"
        echo "customer's orders are on every shard. The application asks for one customer's"
        echo "recent orders and the router can no longer name one shard. Say how many shards"
        echo "that query has to reach and what has to happen to the results."
        exit 1
      fi

      echo "PASS — the busiest shard holds ${maxpct}% of the orders, the next five thousand"
      echo "writes split ${nextpct}% at worst, and no customer is spread across two shards."
