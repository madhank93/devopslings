---
title: "checkout writes at a third of the speed it did in spring"
---

## The situation

Checkout inserts one row into `orders`. The statement has not changed, the
hardware has not changed, and the table is the same ten million rows it was in
spring. It is now roughly a third as fast.

```
/work/app/bench.sh
```

`orders` has six indexes. Three came with the schema. The others were added
over the year by people fixing real read problems, one at a time, each of them
obviously worth it at the time. Nobody has asked since whether anything still
reads through them.

`/work/app/workload.sql` is every query this table serves. There is nothing
else — no reporting replica, no analytics job, no admin console beyond what is
in that file.

## Your objectives

- Find out which indexes the workload actually reads through
- Get the write path back without breaking any of the four queries

## What you're being graded on

The grader runs all four queries and fails any that has become a sequential
scan of the table. Then it requires that every index still on `orders` was read
at least once by that workload — an index nothing reads is dead weight on every
insert. Finally it re-runs `/work/app/bench.sh` and requires at least double
the rate recorded in `/work/app/baseline.txt`. You also fill in
`/work/answers/index-cost.md`.

<details>
<summary>Hint 1 — the counter already exists</summary>

Postgres has been counting this the whole time:

```sql
SELECT indexrelname,
       idx_scan,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size
  FROM pg_stat_user_indexes
 WHERE relname = 'orders'
 ORDER BY idx_scan;
```

`idx_scan` is how many times the planner has gone through that index since the
counters were last reset. Reset them for this table, run
`/work/app/workload.sql`, and look again — that turns a number nobody knows
the start date of into a measurement of the workload in front of you.

```sql
SELECT pg_stat_reset_single_table_counters(indexrelid)
  FROM pg_stat_user_indexes WHERE relname = 'orders';
```

</details>

<details>
<summary>Hint 2 — an index on an expression is only reachable through that expression</summary>

Two of the six are not on a column. `lower(reference)` and `md5(reference)` are
indexes on the *result* of a function, and the planner will only use one of
them for a query that wraps the column in exactly that function. Every query in
the workload compares `reference` directly, so neither index is reachable from
any of them — and no amount of reading the query text tells you that, which is
why the counter is the tool.

This is the same mechanism as the-index-that-is-not-used, seen from the other
end: there a function around the column made an index unusable, here an index
built around a function is unusable without one.

</details>

<details>
<summary>Hint 3 — what an index costs a write</summary>

An insert writes the row once. Then, for every index on the table, it writes an
index entry pointing at that row, WAL-logs that entry, and possibly splits a
B-tree page to make room for it.

That cost scales with the number of indexes and with how random the key is.
`/work/app/bench.sh` inserts random customers, references and dates on purpose:
an append-only batch only ever touches the right-hand edge of each index, which
stays in shared buffers and hides the whole problem. Real checkouts are random.

Before you drop anything, be sure. A `DROP INDEX` on ten million rows is
instant; building it again is not, and the rebuild happens while the incident
is on.

</details>

<details>
<summary>Solution</summary>

Reset the counters, run the workload, and read the result:

```sql
SELECT pg_stat_reset_single_table_counters(indexrelid)
  FROM pg_stat_user_indexes WHERE relname = 'orders';
\i /work/app/workload.sql
SELECT indexrelname, idx_scan FROM pg_stat_user_indexes
 WHERE relname = 'orders' ORDER BY idx_scan;
```

```
 orders_lower_reference_idx | 0
 orders_reference_md5_idx   | 0
 orders_pkey                | 1
 orders_customer_id_idx     | 1
 orders_placed_at_idx       | 1
 orders_reference_idx       | 1
```

Four indexes are each carrying one query. Two are carrying nothing, and between
them they are 450MB of B-tree being maintained on every insert.

```sql
DROP INDEX orders_lower_reference_idx;
DROP INDEX orders_reference_md5_idx;
```

The write path comes back and all four queries keep their plans.

### The part worth remembering

**An index is a standing charge on every write, paid whether or not anything
reads it.** One insert becomes one row plus one index entry per index, each
WAL-logged, each possibly splitting a page. Six indexes is six times the index
work on a table whose whole job is accepting orders.

**The read cost of an index is visible and the write cost is not.** A slow
query gets a ticket and an index gets added. Nothing ever files a ticket saying
"checkout is 8ms slower than last month", so indexes accumulate in one
direction only. `pg_stat_user_indexes` is the other direction, and nothing
looks at it unless someone decides to.

**Measure the write path with the key distribution you actually have.** A
benchmark that inserts sequential ids touches the right-hand edge of every
index, keeps those pages hot in shared buffers, and reports a number that has
nothing to do with production. Random keys are what make index maintenance cost
what it costs.

**`idx_scan = 0` is evidence, not proof.** The counter runs from the last
statistics reset on this server. An index serving a quarterly report reads zero
for months; an index only used on a read replica reads zero here and is
essential there; a unique index enforcing a constraint can read zero forever
and still be the only thing preventing duplicate rows. Reset deliberately,
watch for a period long enough to contain the rare callers, and check for
constraint-backing before dropping — `pg_index.indisunique` and
`pg_constraint` say which.

**Prefer redundancy over absence when you are unsure.** Dropping is fast and
reversible in principle; in practice the rebuild on a large table takes minutes
to hours and you will be doing it under load, with the queries you dropped it
for timing out. Postgres has no invisible-index switch to test with, the way
MySQL does — what it has is `BEGIN; DROP INDEX …;` then checking the plans and
`ROLLBACK`, which answers the question honestly but holds an
`ACCESS EXCLUSIVE` lock on the table while you do it, so it belongs on a clone
rather than on the primary at four in the afternoon.

</details>
