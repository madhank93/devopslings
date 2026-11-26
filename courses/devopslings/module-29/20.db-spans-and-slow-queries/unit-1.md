---
title: "p99 is in the database, and the account page runs a dozen queries"
---

## The situation

`orders` serves the account page, `GET /account`. Each request runs twelve
queries against the shop database: db-stack's Postgres primary, with ten
million orders and 200,000 customers, reachable from the box as `pg:5432`
(database `shop`, user `postgres`, password `devopslings`). The source is
`/obs/apps/orders.py`.

The page's p99 is almost all database time. The team has been staring at
the one query in the code that looks expensive, a join with a `GROUP BY`
and a `HAVING`, and arguing about how to rewrite it.

Every query is a `CLIENT` span under the request's `SERVER` span, and each
carries the database semantic conventions:

| Attribute | Example |
|---|---|
| `db.system.name` | `postgresql` |
| `db.namespace` | `shop` |
| `db.query.text` | the statement, with its placeholders (`db.statement` on older SDKs) |

Postgres keeps its own record of every statement in `pg_stat_statements`,
normalised: parameters become `$1`, `$2`, and each distinct statement has a
`queryid` with its call count and timings.

## Your objectives

1. Find the statement that makes the page slow, from the spans: its
   `db.query.text`, and its `queryid` in `pg_stat_statements`. Put both in
   `/obs/answers/slow-query.txt`.
2. Fix it in the database so that statement's spans take under 5ms at p95.
   The application's queries stay as they are.

## What you're being graded on

- `query` is the slow statement's `db.query.text`, and `queryid` is the
  matching row in `pg_stat_statements`
- over the 20 seconds before the check, that statement's spans have a p95
  under 5ms
- `/obs/apps/orders.py` is unchanged

<details>
<summary>Hint 1 — reading the spans</summary>

A TraceQL search with `spss` returns spans with their durations:

```
curl -s -G http://tempo:3200/api/search \
  --data-urlencode 'q={resource.service.name="orders" && kind=client} | select(span.db.query.text)' \
  --data-urlencode spss=12 --data-urlencode limit=20 | jq
```

Sort by `durationNanos`. One statement is at the top of every trace.

</details>

<details>
<summary>Hint 2 — the plan</summary>

In Python with `psycopg` (installed in the box), run `EXPLAIN ANALYZE` on the
statement with a real email, `customer42@example.invalid`. What does it
scan?

</details>

<details>
<summary>Solution</summary>

The slow spans all carry:

```
db.query.text = SELECT id FROM customers WHERE email = %(email)s
```

It is the most innocent-looking query on the page, and `customers` has no
index on `email`, so every call is a sequential scan of 200,000 rows. In
`pg_stat_statements` it appears as `SELECT id FROM customers WHERE email = $1`,
with the highest total time of the page's twelve:

```sql
SELECT queryid, calls, round(mean_exec_time::numeric, 2) AS mean_ms, query
FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 5;
```

The fix:

```sql
CREATE INDEX customers_email_idx ON customers (email);
```

The span drops from tens of milliseconds to well under one. The big join
was fast all along: it reads one customer's orders through the
`customer_id` index.

### The ways this goes wrong

- **Rewriting the big join.** It looks expensive and runs in a millisecond.
  Code that looks slow is a guess; a span duration is a measurement.
- **Matching by eye in pg_stat_statements.** The span has `%(email)s`, the
  statistics have `$1`. The `queryid` is what ties a statement to its
  numbers across tools.
- **Caching the result in the application.** The query stays slow, and the
  first request for every customer still pays for it.
- **Slow-query log only.** `log_min_duration_statement` is 1s here; this
  statement is never that slow, it is just slow many times per page.

</details>
