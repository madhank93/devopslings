---
title: "the page takes five seconds and nothing in the log is slow"
---

## The situation

`/work/app/page.sh` renders the "recent orders" page: the two hundred newest
orders, each with the email of the customer who placed it. It takes about five
seconds.

```
time bash /work/app/page.sh
```

Support escalated it as a database problem. The DBA sorted the slow-query log
by duration, found nothing above a millisecond, and sent it back as an
application problem. Both of them are reading the same numbers correctly and
reaching the wrong conclusion.

`pg_stat_statements` was reset when this scenario started, so everything in it
is this page's own work.

## Your objectives

- Make the page render inside **500ms**
- It must still print the same two hundred lines, `id|email|total_cents`,
  newest first, read from the database each time
- Fill in `/work/answers/n-plus-one.md`: the `statement:` the page runs too
  many times, and `calls-per-render:`

## What you're being graded on

The grader renders the page itself and counts how many statements that took,
by reading `pg_stat_statements` either side of the render. One is the fix; up
to five is allowed, so pre-loading the customers in a second query passes too.
Zero does not — the page has to actually read the database.

<details>
<summary>Hint 1 — the slow-query log is the wrong instrument</summary>

A slow-query log has a threshold. It records statements that took longer than
`log_min_duration_statement`, which means it is structurally incapable of
telling you about a statement that is always fast.

`pg_stat_statements` has no threshold. It keeps one row per *normalised*
statement — literals replaced by `$1`, `$2` — with the totals for every
execution of it:

```sql
SELECT calls,
       round(total_exec_time::numeric, 1)      AS total_ms,
       round(mean_exec_time::numeric, 3)       AS mean_ms,
       query
  FROM pg_stat_statements
 ORDER BY calls DESC
 LIMIT 5;
```

Order by `calls`. Then order by `total_exec_time` and notice it puts the same
row on top for the same reason.

</details>

<details>
<summary>Hint 2 — read the page as a shape, not as code</summary>

```
one query to get the list
  then, per row in the list, one more query to fill it in
```

That is the shape. One plus N, which is why it has the name it does. It is the
same shape whether the loop is written in bash, in an ORM's lazy relationship,
or in a GraphQL resolver — and in the ORM and GraphQL cases nobody wrote a loop
at all, which is why it survives review.

The database is not slow. It is being asked two hundred times, and each ask is
a round trip: connect or check out a connection, send, parse, plan, execute,
return, repeat. The work is real and none of it is a query.

</details>

<details>
<summary>Hint 3 — two ways to stop asking twice per row</summary>

Ask for both things in one statement:

```sql
SELECT o.id, c.email, o.total_cents
  FROM orders o
  JOIN customers c ON c.id = o.customer_id
 ORDER BY o.id DESC
 LIMIT 200;
```

Or keep the two steps and collapse the inner one into a single call, which is
what a dataloader does and what an ORM calls eager loading:

```sql
SELECT id, email FROM customers WHERE id = ANY('{1,2,3,…}');
```

The first is one statement, the second is two, and both are inside the budget.
The point is not the join — it is that the number of statements stops depending
on the number of rows.

</details>

<details>
<summary>Solution</summary>

Replace the loop with one join.

```bash
psql -qtAX -U postgres -d shop -h 127.0.0.1 -c "
  SELECT o.id, c.email, o.total_cents
    FROM orders o
    JOIN customers c ON c.id = o.customer_id
   ORDER BY o.id DESC
   LIMIT 200"
```

201 statements become 1, and about five seconds becomes about thirty
milliseconds.

The statement that was invisible is:

```
SELECT email FROM customers WHERE id = $1     calls: 200
```

### The part worth remembering

**Cost is `calls × mean`, and only one of those is in the slow-query log.** A
statement at 0.4ms called two hundred times per page costs more than a 60ms
report someone runs twice an hour, and only the report will ever appear in a
log with a threshold. `pg_stat_statements` sorted by `total_exec_time` is the
one ranking that answers "what is this database actually spending its time on",
because it is the only one that multiplies.

**Normalisation is what makes the pattern visible.** Two hundred statements
that differ only by an id would be two hundred forgettable lines in a log.
`pg_stat_statements` folds them into one row with `calls: 200`, and the problem
names itself. This is also why the `query` column has `$1` in it and why you
cannot copy it out and run it.

**N+1 is usually written by a framework, not by a person.** Nobody types this
loop. An ORM does it when a template touches `order.customer.email` inside an
iteration, and the fix is `select_related` / `includes` / `JOIN FETCH`
depending on the framework. A GraphQL server does it once per field per node,
which is what dataloaders exist to batch. The reason to recognise the shape in
`pg_stat_statements` is that the code will not look like a loop.

**Round trips have their own cost curve, and it is about latency, not
throughput.** These two hundred queries were on a loopback socket. Move the
application one availability zone away from the database — a millisecond each
way instead of a tenth — and the same page gets slower without a single query
changing. It is the reason batching survives as an optimisation long after the
database itself stopped being the bottleneck.

</details>
