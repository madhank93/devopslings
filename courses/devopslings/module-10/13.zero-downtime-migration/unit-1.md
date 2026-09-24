---
title: "the migration is ready and nobody will say when it can run"
---

## The situation

`payments.amount_cents` is a `bigint` in minor units, and six services divide
it by a hundred in six slightly different places. Migration 0117 makes it a
`numeric` in whole units. It is two statements, it has been reviewed, and it
has been sitting in the queue for a fortnight.

```
cat /work/app/migrate.sh
```

The last migration like this took the table away for several minutes on a
Tuesday afternoon, so the rule now is that these run in a maintenance window.
There has not been one.

Three million rows.

## Your objectives

- Get `amount` onto the table as a numeric in whole units, with `amount_cents`
  gone and every row's value preserved
- Do it without the shop ever being refused a read

## What you're being graded on

While your `/work/app/migrate.sh` runs, the grader reads a row by primary key
every 200ms with `lock_timeout = '1s'`. That query names no column the
migration touches, so the only thing that can refuse it is a lock on the table
— and none may be. Afterwards `payments.amount` must be numeric, `amount_cents`
must be gone, the row count unchanged, no nulls, and the total must still match
what it was before divided by a hundred. You also fill in
`/work/answers/migration.md`.

<details>
<summary>Hint 1 — find out which statement is actually expensive</summary>

Not every `ALTER TABLE` is the same animal. Ask Postgres directly, by watching
whether the table's file changes identity:

```sql
SELECT relfilenode FROM pg_class WHERE relname = 'payments';
ALTER TABLE payments ADD COLUMN note text NOT NULL DEFAULT '';
SELECT relfilenode FROM pg_class WHERE relname = 'payments';   -- same
ALTER TABLE payments DROP COLUMN note;
```

A `relfilenode` that does not change means Postgres did not rewrite the table —
it wrote something in the catalogue and moved on, in milliseconds, on three
million rows. Since version 11 that includes `ADD COLUMN ... NOT NULL DEFAULT`
with a constant: the default is stored once and handed to every existing row on
read.

Now do the same around the statement in the migration. That one does change,
because a new type means a genuinely new value for every row, and there is
nowhere to keep three million of those except a new copy of the table.

The lesson is not "ALTER TABLE is dangerous". It is that the dangerous ones are
identifiable, one at a time, before you run them.

</details>

<details>
<summary>Hint 2 — watch what the rewrite does to everyone else</summary>

In one session:

```sql
ALTER TABLE payments ALTER COLUMN amount_cents TYPE numeric(14,2) USING amount_cents / 100.0;
```

In another, while it runs:

```sql
SET lock_timeout = '1s';
SELECT id FROM payments WHERE id = 1234567;
```

```
ERROR:  canceling statement due to lock timeout
```

A plain `SELECT` takes `ACCESS SHARE`. The rewrite holds `ACCESS EXCLUSIVE`,
which is the one mode that conflicts with every other mode including that one.
So the read does not get a stale answer or a slow answer — it does not get an
answer.

```sql
SELECT pid, mode, granted, relation::regclass FROM pg_locks
 WHERE relation = 'payments'::regclass;
```

A maintenance window does not change how long that lock is held. It changes how
many people are queued behind it.

</details>

<details>
<summary>Hint 3 — three phases, none of them long</summary>

**Expand.** Add the new column nullable and with no default. Catalogue change,
instant. A `NOT NULL` here would put the table scan straight back.

**Backfill.** Fill it a bounded batch at a time, keyed on the primary key:

```sql
UPDATE payments SET amount = amount_cents / 100.0
 WHERE id >= $lo AND id < $lo + 100000 AND amount IS NULL;
```

Each statement takes row locks, which readers do not wait on, and finishes
quickly enough that it is never the thing anybody is queued behind. The
`amount IS NULL` makes the pass re-runnable, so an interrupted backfill is
resumed rather than restarted.

**Contract.** Drop the old column. Also a catalogue change — the data stays in
the pages and stops being addressable — so it takes the table lock for the
instant it needs rather than for the length of a rewrite.

The whole thing takes longer in wall-clock than the single statement did. That
is the trade: the total is worse and the maximum is what matters.

</details>

<details>
<summary>Solution</summary>

```bash
# expand — catalogue only
psql -c "ALTER TABLE payments ADD COLUMN IF NOT EXISTS amount numeric(14,2)"

# backfill — bounded batches, resumable
lo=$(psql -tAc "SELECT min(id) FROM payments")
hi=$(psql -tAc "SELECT max(id) FROM payments")
while [ "$lo" -le "$hi" ]; do
  psql -c "UPDATE payments SET amount = amount_cents / 100.0
            WHERE id >= $lo AND id < $lo + 100000 AND amount IS NULL"
  lo=$(( lo + 100000 ))
done

# contract — catalogue only
psql -c "ALTER TABLE payments DROP COLUMN amount_cents"
```

Measured on the sandbox, three million rows: the single statement takes about
three seconds and refuses every read for all three. The three-phase version
takes about thirteen, and refuses none.

### The part worth remembering

**The number that matters is the longest single lock, not the total time.** The
safe migration here is four times slower end to end. Nobody notices, because no
individual statement holds the table for more than a moment. Optimising a
migration for total duration is how you get one fast statement that stops the
business.

**Find out which statements rewrite, on your version, before you plan around
them.** `ADD COLUMN NOT NULL DEFAULT <constant>` was a table rewrite until
Postgres 11 and has been free ever since, and plenty of runbooks still forbid
it. Meanwhile `ALTER COLUMN TYPE`, a `STORED` generated column, and a default
that is *volatile* rather than constant all rewrite today. `relfilenode` before
and after, on a scratch copy, answers it in seconds and does not care what the
runbook says.

**A maintenance window buys witnesses, not time.** It is worth having for a
change you cannot make safe. It is not a substitute for making the change safe,
and treating it as one is how a fortnight of queued migrations accumulates —
each one waiting for a window that is never quite convenient, while the
schema drifts further from what the code expects.

**Expand and contract are separate deploys in real life.** Here both phases run
in one script because nothing else is writing. In production the application
has to be able to read and write through every intermediate state: deploy code
that writes both columns, backfill, deploy code that reads the new one, then
drop the old. The database change that cannot be split that way — a rename, in
particular — is the one to design out rather than schedule.

**Bounded batches need a bound you can resume from.** Keying on the primary key
with `amount IS NULL` means an interrupted backfill picks up where it stopped
and a re-run costs nothing. A backfill with no such key, or one that scans the
whole table each pass to find remaining work, gets slower as it progresses and
cannot be safely interrupted — which matters, because it will be.

</details>
