---
title: "the table is ten times its data size and nothing was inserted"
---

## The situation

`inventory` has fifty thousand rows. It had fifty thousand rows last week and
it will have fifty thousand next week — the restock job updates every one of
them every few minutes and inserts nothing.

The file behind it is ten times the size of the data in it, and still growing.

```
psql -h 127.0.0.1 -U postgres -d shop -c "
  SELECT pg_size_pretty(pg_relation_size('inventory')) AS on_disk,
         n_live_tup, n_dead_tup
    FROM pg_stat_user_tables WHERE relname = 'inventory'"
```

Autovacuum is enabled, is running, and is not erroring. Disk is filling at
about a gigabyte a week on a table holding two and a half megabytes of data.

## Your objectives

- Find out why autovacuum is reclaiming nothing, and stop it
- Get the space back into the table without taking the table away from the
  restock job

## What you're being graded on

The grader requires that `n_dead_tup` has come down and that nothing is still
stopping vacuum from removing what comes next, and that `inventory` still has
the relfilenode it started with — a rewrite gives the space back and takes the
table offline to do it. Then it runs ten more restock passes and requires the
file not to grow. You also fill in `/work/answers/bloat.md`.

<details>
<summary>Hint 1 — ask vacuum what it found</summary>

Run it by hand and read the output rather than the exit code:

```sql
VACUUM (VERBOSE) inventory;
```

```
tuples: 0 removed, 550000 remain, 500000 are dead but not yet removable
removable cutoff: 812, which was 10 XIDs old when operation ended
```

Half a million dead row versions, none of them removable. That is not a
failure — vacuum did exactly what it is for and found that it was not allowed
to touch anything. The interesting number is the cutoff, and why it has not
moved.

An `UPDATE` in Postgres does not change a row. It writes a new version and
leaves the old one behind for anyone whose view of the database still includes
it. Vacuum's whole job is deciding that nobody's does.

</details>

<details>
<summary>Hint 2 — somebody's view still includes them</summary>

```sql
SELECT pid, application_name, state,
       backend_xmin,
       now() - xact_start AS open_for,
       now() - state_change AS idle_for
  FROM pg_stat_activity
 WHERE datname = 'shop' AND backend_xmin IS NOT NULL
 ORDER BY xact_start;
```

`backend_xmin` is the oldest transaction id that session still needs to be able
to see. Nothing newer than the lowest `backend_xmin` in the database can be
removed by vacuum, from any table in it — one forgotten transaction pins the
horizon for every table.

Note the state. It is not running a query and it is not blocked on a lock. It
ran one statement and has been sitting in `idle in transaction` ever since.

Not every such session does this. Under `READ COMMITTED` the snapshot is
released when the statement ends, so an idle transaction has a null
`backend_xmin` and pins nothing — it is bad practice and it is not this bug.
This report asked for `REPEATABLE READ`, because it wants one consistent view
across a dozen queries, and that snapshot is registered until the transaction
ends. That is the difference between a session that is merely untidy and one
that costs a gigabyte a week. Filter on `backend_xmin IS NOT NULL`, not on the
state.

`idle_in_transaction_session_timeout` is the setting that would have ended this
by itself.

</details>

<details>
<summary>Hint 3 — two different things called "reclaiming"</summary>

Once the horizon moves, a plain `VACUUM` removes the dead versions and puts
their space on the table's free space map. The file does not get smaller. The
next restock pass writes into those pages instead of extending the table, and
the growth stops. It takes no lock that blocks readers or writers.

`VACUUM FULL` writes a whole new copy of the table and swaps it in. The file
does get smaller. It holds an `ACCESS EXCLUSIVE` lock for the entire rewrite —
every read and every restock pass queues behind it — and it needs room for a
second copy of the table on disk while it runs. On a table that is being served
it is an outage you scheduled.

Which one you want depends on whether the space needs to go back to the
filesystem or back to the table. Here the table is about to use it again.

</details>

<details>
<summary>Solution</summary>

```sql
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
 WHERE datname = 'shop' AND state = 'idle in transaction';

VACUUM (ANALYZE) inventory;
```

The horizon moves, the half-million dead versions become removable, and the
pages go on the free space map. The file stays at 27MB and stops growing —
ten more restock passes now fit inside it.

### The part worth remembering

**Autovacuum failing silently and autovacuum being blocked look identical from
outside.** It was running on schedule the whole time and reporting success.
`VACUUM VERBOSE`'s "dead but not yet removable" is the line that distinguishes
them, and nothing surfaces it unless you go and run it.

**It is the snapshot that pins the horizon, not the open transaction.** A
`READ COMMITTED` transaction sitting idle holds no snapshot between statements
and blocks nothing; a `REPEATABLE READ` or `SERIALIZABLE` one holds its
snapshot until it ends, and so does any transaction that has been assigned a
real xid by writing. `backend_xmin IS NOT NULL` is the predicate that tells
them apart, and an alert on `idle in transaction` alone will page you for
sessions that cost nothing while missing the ones that do.

**One held snapshot pins the horizon for the whole database.** Not for the
table it read — the oldest `backend_xmin` among the database's sessions holds
back vacuum on every table in it, and a replication slot or a standby's
`hot_standby_feedback` can do the same across the whole server. A forgotten
report bloats the tables that a completely unrelated job is updating. This is the same mechanism
as lock-contention's blocker, except that nothing waits and nothing errors, so
nobody notices for a week.

**The age of the oldest `backend_xmin` is the number to alert on.** Not
long-running queries — those are visible and someone is usually watching them.
A session that ran one statement and stopped is doing no work, holds no lock
anyone is waiting for, and is the most expensive thing on the server.
`idle_in_transaction_session_timeout` ends them for you, and there is very
little reason not to set it.

**Bloat that is reused is not bloat.** A table that is updated constantly will
sit at some steady-state size above its data, and that is correct — the free
space is the buffer the next pass writes into. The failure mode is not "the
file is bigger than the data", it is "the file grows every day". Measure the
trend, not the ratio.

**`VACUUM FULL` is for reclaiming to the filesystem, and it costs the table.**
Reach for it when the table has genuinely shrunk for good — a big delete, an
archived partition — and you need the disk back. Reaching for it because a
dashboard showed a ratio is how a bloat problem becomes an availability
incident. `pg_repack` does the same rewrite without the long lock, at the cost
of being an extension somebody has to install and of needing the disk space
anyway.

</details>
