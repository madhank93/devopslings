---
title: "two jobs, one batch, and one of them is killed every night"
---

## The situation

Two nightly passes run over the same settlement batch — six orders. Reconcile
marks them settled, audit stamps them checked. They are scheduled a minute
apart and they overlap whenever the first one runs long.

Most nights both finish. Some nights one dies:

```
ERROR:  deadlock detected
```

and the batch is left half-stamped. By morning nothing is locked, nothing is
waiting, and both jobs run perfectly when you run them by hand. Reproduce it
the way cron does:

```
/work/app/settle.sh reconcile & /work/app/settle.sh audit & wait
```

The on-call fix so far has been to catch the error and run it again.

## Your objectives

- Work out why two jobs that are each correct cannot run at the same time
- Make them survive running together, without either one skipping work

## What you're being graded on

The grader runs each job alone first and requires it to stamp all six orders:
a pass that touches fewer rows has fewer rows to collide on, which is not the
same thing as the collision being fixed. Then it runs the two
concurrently four times over and requires `pg_stat_database.deadlocks` not to
move. A retry loop fails that check: the server counts the deadlock whether or
not your code goes round again. You also fill in `/work/answers/deadlock.md`.

<details>
<summary>Hint 1 — the error tells you it was a cycle, not a wait</summary>

The client gets the shape of it:

```
ERROR:  deadlock detected
DETAIL:  Process 8978 waits for ShareLock on transaction 802; blocked by process 8977.
         Process 8977 waits for ShareLock on transaction 803; blocked by process 8978.
```

Two processes, each waiting for a transaction the other is running. That is a
cycle, and no amount of waiting resolves it — which is why Postgres did not
wait. It waited `deadlock_timeout` (one second, by default), ran the detector,
found the loop, chose one side and threw its transaction away.

The two *statements* involved are in the server log rather than in the client
error — this image logs to the container's stdout, so from the host:

```
docker compose -f sandboxes/db-stack/compose.yaml -p devopslings-db-stack \
  logs primary | grep -A6 'deadlock detected'
```

</details>

<details>
<summary>Hint 2 — watch the locks while it happens</summary>

Start the two jobs, and from a third session look at who is waiting on what:

```sql
SELECT a.pid, a.state, a.wait_event_type, a.wait_event,
       left(a.query, 60) AS query
  FROM pg_stat_activity a
 WHERE a.datname = 'shop' AND a.pid <> pg_backend_pid()
   AND a.state <> 'idle';
```

and the locks behind it:

```sql
SELECT pid, locktype, relation::regclass, transactionid, mode, granted
  FROM pg_locks WHERE NOT granted;
```

Each job is waiting on a row the other one has already updated. Now ask which
rows each of them takes, and in what sequence — both jobs select the same six
ids before they start, and both sort them first.

</details>

<details>
<summary>Hint 3 — retrying is a policy, not a fix</summary>

A retry is worth having: deadlocks can happen for reasons you do not control,
and a job that dies on one is a job that pages someone. But look at what a
retry costs here. The server waited a full `deadlock_timeout` before it even
noticed, then rolled an entire transaction's work back, and only then does your
code start again — into the same two jobs taking the same six rows in the same
two orders. The cycle forms again on the next overlap. The retry decides who
pays for it.

The property that makes a cycle impossible is that every transaction takes the
same locks in the same sequence. Two transactions ordered the same way can only
queue behind each other. Any total order will do — id, primary key, whatever —
as long as both sides use it.

</details>

<details>
<summary>Solution</summary>

The two jobs sort the same batch by different columns:

```bash
reconcile) order="id";             status="reconciled" ;;
audit)     order="placed_at DESC"; status="audited" ;;
```

`placed_at` rises with `id` across this batch, so "newest first" is the exact
reverse of "id order". Reconcile holds row 3 and wants row 4; audit holds row 4
and wants row 3. Neither job is wrong. The pair is.

```bash
ids=$(P -c "SELECT id FROM orders WHERE reference LIKE 'BATCH-%' ORDER BY id")
```

for both. The audit pass loses its newest-first output ordering, which is worth
less than the guarantee it buys.

### The part worth remembering

**A deadlock is a property of a pair, not of a statement.** Nothing in either
job is incorrect, which is why reading one of them finds nothing and why both
pass their own tests. The bug only exists in the set of code paths that touch
the same rows, and it is invisible unless you go looking for the *order* each
of them acquires locks in.

**Consistent lock ordering is the fix that scales.** Pick a total order over
the rows — primary key is the obvious one — and have every writer take them
that way. It costs nothing at runtime and it removes the possibility rather
than the symptom. The same rule applies across tables: if one path writes
`orders` then `customers`, no path may write `customers` then `orders`.

**Retry anyway, but know what it is for.** A retry with backoff is correct
engineering for the deadlocks you cannot design away, and it belongs in the job
regardless. It is not a fix for a cycle your own two jobs form every night: it
converts a loud failure into a slow one, pays `deadlock_timeout` plus a full
rollback each time, and hides the defect from everyone who would otherwise have
noticed it.

**`deadlock_timeout` is a detection delay, not a budget.** Postgres does not
look for cycles on every lock wait — that would cost more than it saves — so it
waits a second first, which means every deadlock costs at least a second of
latency before anyone is told. Lowering it makes detection faster and the
checking more expensive; it does not make deadlocks less likely.

**Count them, do not wait to be told.** `pg_stat_database.deadlocks` is a
running total per database. A deadlock that is caught and retried leaves no
error anywhere your application can see, and this counter is the only thing
that still knows it happened. Alert on the rate of change, not on the log line.

</details>
