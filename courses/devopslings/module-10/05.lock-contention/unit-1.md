---
title: "the migration is forty minutes in and the whole table is frozen"
---

## The situation

`migration-0042` adds one column to `orders`. It started at 09:20 and it is
still running. Since about 09:21 the support channel has been filling up with
reports that order pages time out.

The obvious reading is that ten million rows take a long time to rewrite. That
is not what is happening — adding a column with a default has been a
catalogue-only change since Postgres 11, and takes about a millisecond on any
size of table.

```
export PGPASSWORD=devopslings
psql -h 127.0.0.1 -U postgres -d shop -c 'SELECT count(*) FROM orders'
```

That hangs too. Ctrl-C it.

The two scripts involved are `/work/app/migrate.sh`, already running and
blocked, and `/work/app/reporting-export.sh`, the nightly finance export.

## Your objectives

- Get the migration through, so `orders` has its `currency` column
- Leave no session sitting in an open transaction behind
- Make `/work/app/migrate.sh` give up quickly rather than queue indefinitely
  the next time something holds a lock — while it still runs its `ALTER`

## What you're being graded on

The grader checks the column exists and that nothing is left idle in
transaction. Then it opens a read transaction of its own against `orders`, runs
`/work/app/migrate.sh`, and requires it to fail within thirty seconds instead
of waiting. You also fill in `/work/answers/lock-contention.md`.

<details>
<summary>Hint 1 — ask the database what the migration is waiting for</summary>

`pg_stat_activity` has a row per session, and `pg_blocking_pids()` turns "this
one is waiting" into "on that one":

```sql
SELECT pid, application_name, state,
       wait_event_type, wait_event,
       pg_blocking_pids(pid) AS blocked_by,
       now() - xact_start     AS xact_age,
       left(query, 60)        AS query
  FROM pg_stat_activity
 WHERE datname = 'shop'
 ORDER BY pid;
```

Read the `state` of whatever the migration is blocked by, and read its
`query` column carefully: for an idle session that is the *last* statement it
ran, not one it is running now.

Then the locks themselves, which is where the modes are:

```sql
SELECT a.pid, a.application_name, l.mode, l.granted
  FROM pg_locks l
  JOIN pg_stat_activity a USING (pid)
 WHERE l.relation = 'orders'::regclass
 ORDER BY a.pid;
```

One row has `granted = false`. Everything queued behind it has `granted =
false` too.

</details>

<details>
<summary>Hint 2 — a lock queue, not a lock table</summary>

`AccessShareLock`, which every `SELECT` takes, does not conflict with another
`AccessShareLock`. Readers never wait for readers, so the export alone was
harmless and had been harmless for forty minutes.

What changed is that a request that *does* conflict with both of them arrived
and could not be granted. Postgres does not let later requests overtake it —
if it did, a steady stream of readers would starve the `ALTER` forever. So the
queue is:

```
export        AccessShareLock       granted
migration     AccessExclusiveLock   waiting  (conflicts with the export)
every reader  AccessShareLock       waiting  (behind the migration, not the export)
```

One idle session plus one piece of DDL takes out the table. Either alone does
nothing.

</details>

<details>
<summary>Hint 3 — there is no query to cancel</summary>

`pg_cancel_backend()` cancels a running statement. The export is not running
one: it ran `BEGIN`, ran its `SELECT`, and went away to write a CSV. The state
is `idle in transaction`, the locks are held by the transaction rather than by
the statement, and cancelling nothing changes nothing.

`pg_terminate_backend(pid)` ends the session, which rolls the transaction back
and drops its locks. That is a real decision with a real cost — the export
loses its work — so it belongs to whoever owns that job, and in an incident it
is usually the right call anyway.

For the second objective, look at `lock_timeout`. It bounds how long a
statement will *wait for a lock*, which is not `statement_timeout` (how long it
runs once it starts) and not `idle_in_transaction_session_timeout` (the knob
that would have reaped the export instead).

</details>

<details>
<summary>Solution</summary>

Find it, then end it:

```sql
SELECT pid, application_name, state, now() - xact_start AS open_for
  FROM pg_stat_activity
 WHERE datname = 'shop' AND state = 'idle in transaction';

SELECT pg_terminate_backend(<pid>);
```

The queued migration takes its lock the moment the export lets go, finishes in
about a millisecond, and every reader stacked up behind it drains.

Then bound the next one, in `/work/app/migrate.sh`:

```bash
psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 \
  -c "SET application_name = 'migration-0042'" \
  -c "SET lock_timeout = '3s'" \
  -c "ALTER TABLE orders ADD COLUMN IF NOT EXISTS currency text NOT NULL DEFAULT 'GBP'"
```

Now the migration fails in three seconds with `canceling statement due to lock
timeout`, and the table is never held hostage by it.

### The part worth remembering

**`idle in transaction` is the state to alert on.** It is not running a query,
so it appears in no slow-query log and in no APM trace; it holds every lock the
transaction took and it pins the snapshot horizon, which is separately how
tables bloat while autovacuum has nothing to clean. One alert —
`state = 'idle in transaction' AND now() - xact_start > 1 minute` — catches
this class of incident before anyone files a ticket, and
`idle_in_transaction_session_timeout` enforces it without a human.

**The queue is why a small lock wait is a large outage.** DDL that waits is not
politely standing aside: its ungranted `AccessExclusiveLock` blocks every
reader that arrives after it. The blast radius of a migration is therefore not
"the migration is slow", it is "the table is down", and it grows with how long
it waits. That inversion is exactly what `lock_timeout` is for: a migration
that gives up after three seconds and is retried costs nothing, and one that
waits patiently costs the table.

**Transactions are held open by application code, not by the database.** The
export's transaction spanned a file write. An ORM holds one across an HTTP call
to a payment provider; a script holds one across `sleep`; a connection pool
hands back a session with `BEGIN` still outstanding. The fix upstream is to
read, commit, and *then* do the slow thing — the snapshot you needed was over
the moment you had the rows.

**Ordering matters at every scale here.** This is one transaction blocking one
migration; the same queue with two transactions taking the same locks in
opposite orders is a deadlock, which is the next exercise.

</details>
