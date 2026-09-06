---
title: "the index exists and the planner will not touch it"
---

## The situation

Two queries the application runs constantly. Both are slow. Both have an index
on the column in their `WHERE` clause, and both do a sequential scan anyway.

`/work/queries/lookup.sql` — one order out of ten million:

```sql
SELECT id, customer_id, status, total_cents
FROM orders
WHERE reference::bigint = 10500000;
```

`/work/queries/signin.sql` — one customer out of two hundred thousand:

```sql
SELECT id, country
FROM customers
WHERE lower(email) = 'customer137@example.invalid';
```

`\d orders` shows `orders_reference_idx` on `reference`. `\d customers` shows
`customers_email_idx` on `email`. Neither index is corrupt and neither is
stale. `REINDEX` and `ANALYZE` will not change a thing, and running them is how
this bug survives a week of attention.

## Your objectives

- Make both queries use an index, with `lookup.sql` back under **250ms**
- Both must still return exactly the rows they return now, with the same
  columns — you may change the `WHERE` clause, not what the query is for
- Fill in `/work/answers/indexes.md`: `lookup-cause:` and `signin-cause:`, each
  naming what the query does to the column

## What you're being graded on

The grader takes both plans itself, and requires no sequential scan over
`orders` or `customers`, results identical to the ones the queries return now,
`lookup.sql` inside its budget, and both causes named.

<details>
<summary>Hint 1 — the index does not hold what you think it holds</summary>

A btree index is a sorted copy of a *value*. `orders_reference_idx` holds the
text in `reference`, sorted as text. `customers_email_idx` holds the address as
it is stored.

Now look at what each `WHERE` clause compares. Not `reference` — the number you
get by casting it. Not `email` — the string you get by lowercasing it.

The index cannot help with a value it does not contain. That is the whole bug,
in both queries. `EXPLAIN` shows it in the `Filter:` line: it will say
`(reference)::bigint = ...`, not `reference = ...`.

</details>

<details>
<summary>Hint 2 — two ways out, and only one of them is always available</summary>

If the expression is *incidental*, remove it and the existing index applies.
`reference::bigint = 10500000` is only comparing a number because the literal
was written as a number; `reference = '10500000'` asks the same question of the
same data and `orders_reference_idx` answers it.

If the expression is *the point*, you cannot remove it, so index it instead:

```sql
CREATE INDEX name ON table ((expression));
```

The doubled parentheses are required — the outer pair belongs to the index
definition, the inner pair marks an expression rather than a column name.

Before you decide `lower()` is incidental, look at what row 137 actually
contains.

</details>

<details>
<summary>Hint 3 — an expression index has statistics of its own</summary>

An expression index is a real index and a real statistics target. `ANALYZE`
collects a histogram for the expression once such an index exists, which is
also how the estimate that was wrong in the previous exercise gets fixed.

Create the index, then `ANALYZE` the table, then read the plan again.

</details>

<details>
<summary>Solution</summary>

Index the expressions. Both queries are then left untouched.

```sql
CREATE INDEX orders_reference_bigint_idx ON orders (((reference)::bigint));
CREATE INDEX customers_email_lower_idx   ON customers (lower(email));
ANALYZE orders;
ANALYZE customers;
```

`lookup.sql` goes from a sequential scan of ten million rows to an index scan
returning one — roughly a second down to a fraction of a millisecond.

For `lookup.sql` the alternative is legitimate: change the predicate to
`reference = '10500000'` and `orders_reference_idx` serves it. Both pass. For
`signin.sql` there is no alternative, because row 137 is stored as
`Customer137@Example.invalid` — the `lower()` is doing real work, and deleting
it loses the row.

### The part worth remembering

**An index covers an expression, not a column.** A plain index on `c` is an
index on the expression `c`, which is why it answers `WHERE c = x` and nothing
else. `WHERE f(c) = x`, `WHERE c::other = x`, `WHERE c || '' = x` — all
different expressions, all unindexed until you say otherwise. This is the same
fact behind `WHERE date_trunc('day', ts) = ...` and `WHERE substr(code,1,3) =
...` being slow on tables with a perfectly good index on `ts` and `code`.

**The cast is often invisible in the query text.** `reference::bigint` is
explicit here so it can be pointed at. In real code it usually is not: compare
a `text` column to an integer parameter, or a `bigint` column to a value your
driver sends as `numeric`, and Postgres inserts the cast for you. The query
looks like it filters on the column. The `Filter:` line in `EXPLAIN` is where
you find out it does not.

**Which side gets cast decides whether you have a problem.** Postgres will
happily cast the *literal* to the column's type when it can, and then the index
applies and nothing is wrong. It casts the *column* when the literal cannot be
converted without losing the comparison's meaning — and casting the column is
what disables the index. So the question is never "is there a cast" but "which
operand did it land on".

**Expression indexes are not free.** Each one is a second copy of the data to
build, keep in cache, and update on every write, and the expression is
evaluated on every insert and update of that row — so it must be `IMMUTABLE`,
which is why `lower(email)` is allowed and `now() - created_at` is not. If the
expression can be lifted out of the query instead, that is the cheaper fix.
Module 10's `index-that-costs-more-than-it-saves` is what happens when this
reasoning is skipped six times in a row.

</details>
