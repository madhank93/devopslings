---
title: "four shards, and one of them is doing all the work"
---

## The situation

Orders were split across four shards a year ago, and for a year it was fine.
Now one shard sits at 80% CPU through the evening peak while the other three
are idle, and it is the same shard every evening.

```sql
SELECT shard, count(*) FROM all_orders GROUP BY shard ORDER BY shard;
```

The application never queries `all_orders` — that view exists so you can see
all four at once. In production it asks the router where a row lives and then
talks to that one shard:

```
cat /work/app/router.sql
```

The plan on the whiteboard is a fifth shard, on the grounds that four machines
are not enough for the load. Four machines are plenty for this load.

The read the application does most, by a wide margin, is *this customer's
recent orders*.

## Your objectives

- Find what the shard key is doing and fix it, so no shard holds more than 35%
  of the orders and the next five thousand writes split the same way
- Keep every customer's orders on a single shard, so the common read still has
  exactly one place to go
- Move the rows that are already there to wherever the new router looks for
  them

## What you're being graded on

`shard_for(int, int, bigint)` keeps its name and signature and still answers
0–3. All 400000 orders are still there, each on exactly one shard, and each on
the shard its own router names. The busiest shard holds at most 35% of them,
and so does the busiest shard for a simulated next five thousand orders. No
customer's orders are split across shards, and `shard_for` gives the same
answer for a customer whichever order id it is handed. You also fill in
`/work/answers/sharding.md`.

<details>
<summary>Hint 1 — ask what the hot shard's rows have in common</summary>

The shard is not hot because of its hardware. It is hot because of what is on
it:

```sql
SELECT tenant_id, count(*) FROM shard_2 GROUP BY 1 ORDER BY 2 DESC LIMIT 5;  -- the busy one
SELECT tenant_id, count(*) FROM all_orders GROUP BY 1 ORDER BY 2 DESC LIMIT 5;
```

One tenant places seven orders in ten. The router hashes the tenant id, a hash
is a function, and a function sends one input to one output — so that tenant's
entire workload resolves to a single shard, by construction, on any day of the
week.

Now the fifth shard. It changes the modulus, so every tenant gets rehashed and
plenty of rows move. What it cannot do is split a single hash value across two
shards. The big tenant lands somewhere, and wherever that is takes 70% of the
writes.

**A shard key with fewer distinct values than you have shards, or with one
value that dominates, cannot be rebalanced by adding capacity.** That is a
property of the key, and the only thing that fixes it is a different key.

</details>

<details>
<summary>Hint 2 — the obvious fix is the wrong one</summary>

`hashtextextended(p_order::text, 0)` spreads the writes perfectly: order ids
are unique, so each shard takes a quarter, exactly, forever.

Then look at what the application actually asks for:

```sql
SELECT * FROM shard_?? WHERE tenant_id = 42 AND customer_id = 17
 ORDER BY placed_at DESC LIMIT 20;
```

The router cannot fill in that `??` any more, because the answer depends on the
order id and the whole point of the query is that you do not know the order ids
yet. So the read goes to all four shards, and you merge and re-sort four result
sets in the application. One query became four, its latency became the slowest
shard's, and it now fails whenever any shard is down.

The best distribution is not the best key. The key has to spread the writes
*and* keep whatever the common read asks for on one shard.

</details>

<details>
<summary>Hint 3 — pick the narrowest unit the common read never crosses</summary>

The common read is scoped to one customer. So a customer must not be split —
but nothing says a tenant cannot be.

```sql
CREATE OR REPLACE FUNCTION shard_for(p_tenant int, p_customer int, p_order bigint)
RETURNS int LANGUAGE sql IMMUTABLE AS $fn$
  SELECT ((hashtextextended(p_tenant::text || ':' || p_customer::text, 0) % 4 + 4) % 4)::int
$fn$;
```

The big tenant has 800 customers, so its traffic now spreads over four shards
instead of one, while `tenant = 42 AND customer = 17` still resolves to exactly
one shard the router can name.

Changing the function does not move any data. Every row already placed is now
on a shard the router will not look at, which is the same as gone:

```sql
BEGIN;
CREATE TEMP TABLE rebalance AS
  SELECT * FROM shard_0 UNION ALL SELECT * FROM shard_1 UNION ALL
  SELECT * FROM shard_2 UNION ALL SELECT * FROM shard_3;
TRUNCATE shard_0, shard_1, shard_2, shard_3;
INSERT INTO shard_0 SELECT * FROM rebalance WHERE shard_for(tenant_id, customer_id, order_id) = 0;
-- and so on
COMMIT;
```

</details>

<details>
<summary>Solution</summary>

```sql
-- the key: tenant and customer together
CREATE OR REPLACE FUNCTION shard_for(p_tenant int, p_customer int, p_order bigint)
RETURNS int LANGUAGE sql IMMUTABLE AS $fn$
  SELECT ((hashtextextended(p_tenant::text || ':' || p_customer::text, 0) % 4 + 4) % 4)::int
$fn$;

-- then move the rows to match, in one transaction
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
```

Four shards at roughly 25% each, and `tenant = 42 AND customer = 17` still
names one of them.

### The part worth remembering

**A hot shard is a statement about the key, not about the capacity.** One hash
value cannot be split across two machines, so if one key value carries most of
the traffic, no amount of hardware divides it. Before you size anything, run
the group-by: if the top value of your shard key is a large fraction of the
rows, that fraction is the floor on your worst shard and adding shards will not
lower it.

**Choose the key from the query you run most, not from the distribution.**
Hashing a unique id gives a perfect spread and a scatter-gather on every read.
Hashing the widest grouping gives one-shard reads and a hot shard. The key you
want is the narrowest unit your common read never crosses — here, a customer:
narrow enough that the big tenant's traffic divides, wide enough that the read
still names one shard.

**Scatter-gather is not just slower, it is differently available.** A read that
touches one shard fails when that shard is down. A read that touches all four
fails when *any* of them is. Fanning out every query trades a 25% chance of
being affected by a failure for a 100% one, and the p99 of a four-way fan-out
is the p99 of the slowest of four.

**Changing the router is half the change.** The function and the placement are
two copies of the same decision, and between the moment you deploy one and the
moment you finish the other, rows exist that the router cannot find. Real
systems bridge that with dual reads — check the new location, fall back to the
old — and drop the fallback once the backfill is done. Here it fits in one
transaction, which is the same idea with the window closed.

**The tenant that dwarfs the rest eventually needs its own answer.** Splitting
by customer works while the big tenant has 800 of them. A tenant with one
customer placing most of the orders puts you back where you started, and at
that point the fix is not a better hash — it is a dedicated shard for that
tenant, with the router carrying an explicit exception.

</details>
