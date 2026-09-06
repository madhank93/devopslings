---
title: "one query, ten million rows, and a planner that guessed wrong"
---

## The situation

A report query runs against `orders`, which has ten million rows, and it takes
seconds. Nobody on the team can say why, because nobody has read the plan —
they have read the *query*, decided it looks fine, and added an index.

```sql
SELECT count(*)
FROM orders
WHERE reference::bigint BETWEEN 10999000 AND 11000000;
```

There is already an index on `reference`.

## Your objectives

Fill in `/work/answers/plan.md`:

- `scan:` which scan the plan chose — `seq`, `index`, `index-only` or `bitmap`
- `estimated-rows:` what the planner expected from that node
- `actual-rows:` what it got
- `why:` where the estimate went wrong, and what the query does that causes it

You are not being asked to make the query fast. That is the next exercise. This
one is about reading the instrument before turning anything.

## What you're being graded on

The grader runs the plan itself and checks your answers against it — the scan
type exactly, the two row counts within a factor of two (they drift a little
between runs), and that `why:` names what happens to the column.

<details>
<summary>Hint 1 — EXPLAIN alone only gives you half of it</summary>

`EXPLAIN` prints what the planner *thinks* will happen. It is free, and it
cannot tell you it was wrong.

`EXPLAIN (ANALYZE)` actually runs the statement and prints both numbers side by
side:

```
Seq Scan on orders  (cost=... rows=50000 width=8) (actual time=... rows=1001 loops=1)
                                  ^ estimate                        ^ reality
```

Add `BUFFERS` and you also get how much of that came from cache versus disk.

**`ANALYZE` here runs the query.** On a `SELECT` that is fine. On an `UPDATE`
or `DELETE` it really does modify data, so wrap those in a transaction you roll
back.

</details>

<details>
<summary>Hint 2 — read the plan from the inside out</summary>

The plan is a tree and it executes bottom-up: the most indented nodes run
first, and each one feeds the node above it.

That is why the *first* wrong estimate is the one that matters. A node that
expects 50,000 rows and gets 1,000 has made every choice above it — join
strategies, sort memory, whether to bother with an index — on a number that was
never true.

So find the deepest node whose estimate and actual disagree, and start there.

</details>

<details>
<summary>Hint 3 — why the index on `reference` is not helping</summary>

The index is on the column. The query does not filter on the column.

`reference::bigint` is an *expression*, and `ANALYZE` collects statistics —
a histogram, the most common values — for columns as they are stored. There is
no histogram for "this text column interpreted as a number", so the planner has
nothing to reason with and falls back to a fixed guess.

An index on `reference` cannot serve a predicate on `reference::bigint` either,
for the same reason: they are not the same thing.

</details>

<details>
<summary>Solution</summary>

The plan chooses a sequential scan. The estimate on that node is a default
selectivity guess — a fixed fraction of the table rather than anything derived
from the data — and the actual row count is about a thousand.

```
scan: seq
estimated-rows: <the scan node's rows=>
actual-rows: <the scan node's actual rows=>
why: The filter is on reference::bigint, not on reference. That cast is an
     expression, and ANALYZE holds statistics only for the column as stored,
     which is text. With no histogram for the expression the planner uses a
     default guess, and the index on reference cannot serve the predicate
     either — an index on a column does not cover a function of that column.
```

### The part worth remembering

**A plan has two numbers per node and only their ratio is interesting.** Cost
units are arbitrary and not comparable to seconds. What tells you something is
`rows=` against `actual rows=`: agreement means the planner understood the
data, and a large divergence means every decision above that node was made on
fiction. Read plans looking for the first big divergence, not the largest cost.

**Estimates go wrong in a small number of recognisable ways.** An expression or
cast the statistics do not cover, which is this case. Correlated columns, where
the planner multiplies two selectivities as if independent — `city` and
`postcode` being the classic. Stale statistics after a bulk load. And a column
whose distribution is genuinely skewed past what the default 100 histogram
buckets can describe, which `ALTER TABLE ... ALTER COLUMN ... SET STATISTICS`
exists for.

**The instinct to "add an index" is what keeps this bug alive.** There *is* an
index on `reference`, and it does nothing, and the team that added it moved on
believing the query was tuned. Reading the plan is what distinguishes an index
that is unused because the planner is wrong from one that is unused because it
cannot possibly apply.

**`EXPLAIN ANALYZE` measures a real execution, so it is affected by the
cache.** The first run reads from disk and the second reads from
`shared_buffers`, and the difference can be an order of magnitude with an
identical plan. `BUFFERS` shows you which you got — `shared hit` against
`shared read` — and stops you concluding that a change helped when what
actually happened is that you ran it twice.

</details>
