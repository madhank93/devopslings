---
title: "the transaction id age keeps climbing and vacuum says it is done"
---

## The situation

A monitoring check has been amber for a fortnight:

```
/work/app/xid-age.sh
```

`ledger` is a quarter of a million transaction ids past its oldest frozen id,
against a freeze threshold of a hundred thousand, and the number goes up every
day. The table holds twenty thousand rows and is barely written to.

Autovacuum is running against it. Repeatedly. On a table where somebody set
`autovacuum_enabled = off` months ago because it was causing IO at the wrong
time of day. Each run finishes without an error and the age does not move.

> The sandbox runs this one table at `autovacuum_freeze_max_age = 100000`,
> the lowest Postgres accepts, so the curve fits in a minute. Production runs
> the 200 million default and takes months to get here. Nothing else about the
> mechanism is scaled down.

## Your objectives

- Find what is stopping the freeze, given it is in no session list
- Bring `ledger`'s transaction id age back under its threshold, with the rows
  still in it
- Be able to say what would have happened if nobody had

## What you're being graded on

The grader requires that nothing is left pinning the transaction id horizon,
that `age(relfrozenxid)` on `ledger` is back under its freeze threshold, and
that all twenty thousand rows are still there. You also fill in
`/work/answers/wraparound.md`.

<details>
<summary>Hint 1 — make vacuum tell you the cutoff it used</summary>

```sql
VACUUM (FREEZE, VERBOSE) ledger;
```

```
tuples: 0 removed, 20000 remain, 0 are dead but not yet removable
removable cutoff: 100970, which was 250001 XIDs old when operation ended
new relfrozenxid: 100970, which is 1 XIDs ahead of previous value
frozen: 0 pages from table (0.00% of total) had 0 tuples frozen
```

There is the whole problem in one line. Vacuum ran, froze nothing, and moved
`relfrozenxid` forward by a single transaction id — because the oldest id it is
allowed to treat as settled is 100970, and that id is a quarter of a million
transactions in the past.

`FREEZE` is not being refused. It is being told it may not go past 100970.

</details>

<details>
<summary>Hint 2 — it has no session, so stop looking in session views</summary>

`pg_stat_activity` has nothing with an old `backend_xmin`. There is no idle
transaction, nothing blocked on a lock, and killing backends achieves nothing.

Three things pin the horizon and only one of them is a session:

```sql
SELECT pid, backend_xmin FROM pg_stat_activity WHERE backend_xmin IS NOT NULL;
SELECT slot_name, xmin, catalog_xmin FROM pg_replication_slots;
SELECT gid, transaction, prepared, owner, database FROM pg_prepared_xacts;
```

A replication slot holds the horizon for a standby that has fallen behind or
gone away. A prepared transaction holds it for a two-phase commit that was
prepared and never resolved — and that one has no process, no connection and no
timeout. `idle_in_transaction_session_timeout` cannot reach it because there is
no session to disconnect. It survives a restart of the server, deliberately:
durability across a crash is the entire reason a transaction gets prepared.

</details>

<details>
<summary>Hint 3 — resolving it is a decision, not a command</summary>

```sql
ROLLBACK PREPARED 'settlement-0091';
-- or
COMMIT PREPARED 'settlement-0091';
```

Both free the horizon. They are not interchangeable: a prepared transaction is
one arm of a distributed transaction, and the other arm has already been told
something. Committing this half when the other half rolled back, or rolling it
back when the other half committed, leaves two systems permanently disagreeing
about whether a settlement happened — quietly, and with no error anywhere.

Find out what the coordinator decided before you decide for it. When the
coordinator is gone for good, `prepared` and `owner` in `pg_prepared_xacts`, the
`gid` itself, and the rows the transaction would add are usually enough to work
out which way it was going.

Then let the freeze finish:

```sql
VACUUM (FREEZE, VERBOSE) ledger;
```

</details>

<details>
<summary>Solution</summary>

```sql
SELECT gid, transaction, prepared, owner FROM pg_prepared_xacts;
```

```
 settlement-0091 | 100970 | 2026-09-24 03:35:55+00 | postgres
```

That transaction id, 100970, is exactly the cutoff vacuum reported. The
settlement was never confirmed to the other side, so:

```sql
ROLLBACK PREPARED 'settlement-0091';
VACUUM (FREEZE, ANALYZE) ledger;
```

```
removable cutoff: 350972, which was 0 XIDs old when operation ended
new relfrozenxid: 350972, which is 250002 XIDs ahead of previous value
```

Age back to zero. And put `autovacuum_enabled` back, which was never the cause
and is still wrong.

### The part worth remembering

**Anti-wraparound vacuum ignores `autovacuum_enabled = off`.** Once a table
passes `autovacuum_freeze_max_age`, Postgres vacuums it whether you asked for
that or not, because the alternative is a server that stops accepting writes.
Turning autovacuum off on a table does not buy you quiet — it buys you a
surprise vacuum at a moment you did not choose, on top of the ordinary bloat
nobody is now clearing.

**At the limit the database refuses writes.** Not slowly, not partially: it
stops accepting commands that would consume a transaction id and tells you to
vacuum it in single-user mode. Getting back from there means downtime measured
in however long a full-database freeze takes on your largest table. This is the
one Postgres failure mode where the warning period is months and the recovery
is not.

**Three things hold the transaction id horizon, and only one is a session.**
An old `backend_xmin`, a replication slot, and a prepared transaction. Monitor
all three. The session one is the one everybody knows about and the easiest to
resolve; the other two survive restarts and have no owner to page.

**A prepared transaction has no process, so nothing reaps it.** No backend, no
`pg_stat_activity` row, no lock wait, no timeout setting that applies. If you
do not use two-phase commit, `max_prepared_transactions = 0` — the default —
means this cannot happen to you. If you do use it, an orphaned `gid` is a
permanent fixture until a human removes it, and it needs its own alert.

**`age(relfrozenxid)` per table, not just `age(datfrozenxid)`.** The database
age is the maximum over its tables, so a single stuck table is invisible in the
aggregate until it dominates it. Alert on the worst table and name it, or the
page tells you the database is unwell and nothing about where to look.

</details>
