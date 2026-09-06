---
title: "the application login can drop every table it reads"
---

## The situation

The service connects to Postgres as a role called `app`. All day it does three
kinds of thing:

```sql
SELECT ... FROM orders WHERE customer_id = ...
INSERT INTO orders ...
UPDATE orders SET status = ...
```

`app` also owns the tables, and was granted `ALL` on the schema. So the
connection string the application carries is also entitled to:

```sql
DROP TABLE orders;
```

Nothing has gone wrong. That is what makes it worth fixing now — the cost of
this arrives all at once, through a SQL injection, a migration tool pointed at
the wrong database, or an ORM's "drop and recreate" development flag reaching
production.

## Your objectives

1. Keep the application working: it must still read and write `orders` and
   `customers`.
2. Make `DROP TABLE orders` fail for `app`.
3. Stop `app` creating tables of its own.

## What you're being graded on

That `app` can still `SELECT`, `INSERT`, `UPDATE` and `DELETE`; that a
grader-run `DROP TABLE orders` is refused with a permission error and the table
survives; that `app` no longer owns `orders`; and that `app` cannot `CREATE
TABLE` in `public`.

<details>
<summary>Hint 1 — revoking is not enough, and this is the part people miss</summary>

The obvious move is to revoke rights from `app`. Try it and the `DROP` still
works.

An **owner** of a table can always drop it. `DROP` is not a privilege that can
be granted or revoked at all — there is no `GRANT DROP` in Postgres. The right
to drop follows ownership, so as long as `app` owns `orders`, no amount of
`REVOKE` will take it away.

So the first change is not a `REVOKE`. It is an `ALTER TABLE ... OWNER TO`.

</details>

<details>
<summary>Hint 2 — grant the verbs, not the object</summary>

`GRANT ALL ON SCHEMA public TO app` is how this happened. `ALL` on a schema
includes `CREATE`, which is what lets a role add objects to it.

What the application needs from the schema is `USAGE` — permission to look
inside it — and then the four statement types it actually issues, on the two
tables it actually touches.

Subtract from `ALL` and you will miss something. Revoke everything and add back
what the workload uses.

</details>

<details>
<summary>Hint 3 — the insert will fail for a reason that is not about the table</summary>

`orders.id` is a `bigserial`, which means it draws from a sequence. A role that
can `INSERT` into the table but has no rights on the sequence gets:

```
ERROR:  permission denied for sequence orders_id_seq
```

Grant `USAGE, SELECT` on the sequences behind the primary keys.

</details>

<details>
<summary>Solution</summary>

```sql
ALTER TABLE orders    OWNER TO postgres;
ALTER TABLE customers OWNER TO postgres;
ALTER SEQUENCE orders_id_seq    OWNER TO postgres;
ALTER SEQUENCE customers_id_seq OWNER TO postgres;

REVOKE ALL ON SCHEMA public FROM app;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM app;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM app;

GRANT USAGE ON SCHEMA public TO app;
GRANT SELECT, INSERT, UPDATE, DELETE ON orders, customers TO app;
GRANT USAGE, SELECT ON SEQUENCE orders_id_seq, customers_id_seq TO app;
```

### The part worth remembering

**`DROP` is not a privilege — it is a consequence of ownership.** This is the
single most common mistake in Postgres permission work, because every other
dangerous verb (`INSERT`, `TRUNCATE`, `REFERENCES`) *is* grantable, so people
assume `DROP` is too and go looking for the `REVOKE` that turns it off. There
isn't one. Ask "who owns this" before "what has been granted".

**The role that runs migrations and the role that serves traffic are different
roles.** Something has to own the schema and be able to change it — that is a
real need, and it belongs to a migration role used by a deliberate, reviewed
process, not to the pool of connections answering HTTP requests. One database,
two logins, and the dangerous one is not the one on the hot path.

**Grant the verbs the workload uses, on the objects it touches.** Starting from
`ALL` and subtracting means the next new privilege Postgres adds is one your
application role silently has. Starting from nothing and adding means the next
thing the application needs fails loudly in staging, which is the failure you
want.

**Default privileges are the trap on the next table.** These grants apply to
tables that exist *now*. Create `order_events` tomorrow and `app` has no rights
on it, and the fix that gets reached for in a hurry is `GRANT ALL`. `ALTER
DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON
TABLES TO app` says what every future table should give it, once.

**Since Postgres 15 the `public` schema is not world-writable by default**, so
a fresh database is less exposed than this one was. That is a floor, not a
policy — `GRANT ALL ON SCHEMA public` puts you straight back here, and it is
still the first thing most setup guides tell you to run.

</details>
