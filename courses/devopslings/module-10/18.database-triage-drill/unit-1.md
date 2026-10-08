---
title: "checkout is slow, and the cause is somewhere in the database"
---

## The situation

```
$ /work/app/checkout.sh
checkout: FAILED CK-1759132211480391920-812 — ERROR:  canceling statement due to statement timeout
```

Checkout is slow and some requests time out. That is the entire ticket, and it
will be the entire ticket every time you run this lesson — because the fault is
drawn at random from five, and every one of them ends in the same line from
the app.

`checkout.sh` is one request. It opens a transaction on the primary with a
150 ms `statement_timeout`, checks the order reference has not been placed
already, takes one unit of `SKU-7` from `stock`, inserts the order and a row in
`checkout_attempts`, commits — and then polls the replica for the order page
the customer lands on. Past the timeout, or past three seconds on the order
page, the customer gets an error.

Nothing in the app is wrong. You cannot memorise the answer. You can memorise
the order you ask the database questions in.

## Why there is an order

A statement that exceeds its timeout has been doing one of two things: waiting
or working. `statement_timeout` does not say which — it cancels a statement
queued on a lock exactly as it cancels one scanning ten million rows. The
database, asked directly, always knows.

Waiting is cheaper to prove and comes first. A statement that is waiting has a
`wait_event_type` of `Lock` and a list of who it is waiting for; that answer
takes one query and rules out every plan question underneath it, because a
statement that never started has no plan worth reading. Only once nothing is
waiting does it make sense to ask how the work is being done.

Then there is the half of the request that does not fail with an error at all:
the order commits, and the page that reads it back from the replica waits for a
row that never arrives.

## The ladder

**1. Is anything waiting on a lock — and behind whom?**

```sql
SELECT pid, application_name, state, wait_event_type, pg_blocking_pids(pid)
  FROM pg_stat_activity WHERE datname = 'shop';
```

Run `checkout.sh` in another terminal while you look, or you may catch nothing
waiting. `pg_blocking_pids()` names the sessions a waiter is queued behind. Follow
the chain to its head — the waiter at the front of a queue is often a victim
too, and a session that is `idle in transaction` is only a problem if something
is queued on it.

**2. Is anything holding locks with no session at all?**

```sql
SELECT gid, prepared, owner FROM pg_prepared_xacts;
SELECT locktype, relation::regclass, mode, pid FROM pg_locks WHERE pid IS NULL;
```

A prepared transaction survives its session, its coordinator and a restart. It
has no row in `pg_stat_activity`, so step 1 finds a waiter with a blocker it
cannot name.

**3. Is the replica applying what it receives?**

```sql
-- on the replica
SELECT pg_is_wal_replay_paused(), pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();
```

Receive moving while replay stands still is a standby told to stop, not a
network problem.

**4. What plan does the lookup get, and why?**

```sql
EXPLAIN ANALYZE SELECT count(*) FROM orders WHERE reference = 'CK-x';
\d+ orders
SELECT n_distinct FROM pg_stats WHERE tablename = 'orders' AND attname = 'reference';
```

A sequential scan on ten million rows has two very different causes: no index
the query *can* use, or an index the planner decided not to use because it
believes the lookup matches most of the table. `\d orders` answers the first —
read what each index is actually on. The estimated rows against the actual
rows answers the second.

## Your objectives

1. Make checkout complete again by repairing what was broken, where it was
   broken. `checkout.sh` stays exactly as it is.
2. Write `/work/answers/triage.md`, three lines:

   ```
   cause:     <what happened, in a few words>
   evidence:  <the query or view that proved it>
   detection: <a signal, and the threshold at which it should have paged>
   ```

## What you're being graded on

**Checkout completes.** The grader runs `checkout.sh` three times and at least
two have to finish, order page included.

**The repair is at the cause.** A changed `checkout.sh` fails outright — a
longer timeout, a read sent to the primary and a skipped lookup each make the
ticket go quiet and fix nothing. Beyond that, each fault has its own sidestep,
and each one is checked:

- ending the migration instead of what it was queued behind — the migration
  has to land
- committing an orphaned prepared transaction instead of rolling it back —
  the stock has to add up to the orders that exist
- promoting the replica — it has to still be a standby
- forcing an index with `enable_seqscan = off` — in a fresh session the
  lookup has to plan as an index scan *and* the estimate has to be near the
  one row it finds

**The idempotency constraint is still there.** Something on this database looks
like dead weight and is not. It has to be there when you finish.

**You can name it.** `cause`, `evidence` and `detection` are each checked
against the fault that was seeded, and `detection` needs a number.

<details>
<summary>Hint 1 — the ladder, four questions</summary>

Keep `checkout.sh` running in a loop in one terminal:

```
while :; do /work/app/checkout.sh; sleep 1; done
```

and in another, in order, stopping at the first one that answers:

```sql
SELECT pid, application_name, state, wait_event_type, pg_blocking_pids(pid)
  FROM pg_stat_activity WHERE datname = 'shop';
SELECT * FROM pg_prepared_xacts;
-- psql -h replica:
SELECT pg_is_wal_replay_paused();
EXPLAIN ANALYZE SELECT count(*) FROM orders WHERE reference = 'CK-x';
```

</details>

<details>
<summary>Hint 2 — four of the five time out identically</summary>

A lock queue, an orphaned prepared transaction, an unusable index and a bad
estimate all produce `canceling statement due to statement timeout`. The first
two are waiting; the last two are working. `wait_event_type` tells them apart
in one query.

The fifth is the only one that does not time out on the primary at all: the
order commits, and the page times out on the replica.

</details>

<details>
<summary>Hint 3 — things that look like the fault and are not</summary>

- `finance-export` is idle in transaction on every run. It only matters when
  something that needs the whole table is queued behind it.
- `checkout_attempts_idempotency_key_key` has `idx_scan = 0` and takes tens of
  megabytes. `idx_scan` counts reads through the index. A unique constraint's
  index is checked on every insert and read by nothing, and it is what stops a
  retried payment being recorded twice.
- An `ANALYZE` on its own does not undo a per-column statistics override; the
  override is re-applied every time.

</details>

## What actually happened

One of five. Which one is in a digest at `/var/lib/drill/state`, not a word —
reading it teaches nothing.

| Fault | What was done | The tell |
|---|---|---|
| lock | `finance-export` idle in transaction on `orders`; `migration-0057` queued behind it for `AccessExclusiveLock`; checkout queued behind the migration | a waiter whose `pg_blocking_pids()` leads to an idle session |
| prepared | `PREPARE TRANSACTION 'checkout-7f3a91'` holding the row lock on `SKU-7` | a row in `pg_prepared_xacts`; a lock in `pg_locks` with no pid |
| replica | `pg_wal_replay_pause()` on the replica | the primary commits; the order page times out; receive LSN moves, replay does not |
| index | `orders_reference_idx` replaced by an index on `lower(reference)` | seq scan; `\d orders` shows no index on the bare column |
| stats | `n_distinct = 1` set on `orders.reference` | seq scan; estimated ~10M rows, actual 1; `\d+ orders` shows the option |

Every one of them is invisible in the slow-query log. The two lock faults never
finish a statement to log. The replica fault never runs a slow statement. The
plan faults are cancelled at 150 ms, well under `log_min_duration_statement`.

<details>
<summary>Solution</summary>

The reference solution is the ladder as a script, each rung checked only if the
ones above it found nothing:

```bash
# 1 — end whatever the lock waiters are queued behind (the holder, not the waiter)
psql -c "SELECT pg_terminate_backend(b) FROM (SELECT DISTINCT unnest(pg_blocking_pids(pid)) b
           FROM pg_stat_activity WHERE wait_event_type = 'Lock') s"

# 2 — an orphaned prepared transaction: its order was never written, so roll back
psql -c "ROLLBACK PREPARED 'checkout-7f3a91'"

# 3 — the replica stopped applying WAL
psql -h replica -c "SELECT pg_wal_replay_resume()"

# 4a — no index the lookup can use
psql -c "CREATE INDEX CONCURRENTLY orders_reference_idx ON orders (reference)"

# 4b — an override lying to the planner
psql -c "ALTER TABLE orders ALTER COLUMN reference RESET (n_distinct)" \
     -c "ANALYZE orders (reference)"
```

Only one of those applies to any run. Then, for example:

```
cause:     finance-export idle in transaction; migration-0057 queued behind it; checkout behind the migration
evidence:  pg_blocking_pids() of the waiting migration, and pg_stat_activity for the holder
detection: page when any session has waited on a lock for more than 5 seconds
```

Detection signals by fault: lock waits or idle-in-transaction age; the age of
rows in `pg_prepared_xacts`; replay lag in seconds; the lookup's
`mean_exec_time` in `pg_stat_statements`, or `seq_scan` on `orders`.

</details>

## Carrying this forward

- **Waiting before working.** A timeout does not tell you which, and
  `wait_event_type` does in one query. Plans are the second question.
- **Follow the queue to its head.** The session everybody sees waiting is
  usually a victim. The one causing it is often doing nothing.
- **Not every lock has a session.** When `pg_blocking_pids()` comes back with
  nothing you can find, look for the prepared transaction.
- **An index being there is not the same as an index being usable** — and an
  index being usable is not the same as the planner believing it is worth it.
- **Unused is not unneeded.** `idx_scan = 0` on a unique index is the index
  doing its only job.

Run the lesson again. The fault moves, and the ladder does not.
