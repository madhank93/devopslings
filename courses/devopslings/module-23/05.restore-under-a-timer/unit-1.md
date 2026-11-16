---
title: "Restore under a timer"
---

## The situation

When the business asks how long a database restore takes, the answer comes
from `/ha/dr/runbook.txt`: **2 seconds**. It was measured in March 2024,
when the `events` table had 40,000 rows. Nobody has timed one since.

`events` has grown. The procedure in `/ha/dr/restore.sh` has not changed.

## Your objectives

1. Run the drill, `/ha/dr/restore.sh`, and time it.
2. Time the same restore again in two halves — the tables and their rows,
   then the indexes and constraints — to see where the time goes.
3. Record all three in `/ha/answers/restore-drill.txt`.
4. Make the runbook honest: a `restore_seconds` you measured, and the
   `measured_rows` it was measured at.

## What you're being graded on

The grader runs the same restore in the same two halves and times them.

- Your three timings must each be within a factor of two of its own.
- The runbook's `restore_seconds` must be at least what the restore takes, and
  no more than the shop's one-hour RTO.
- `measured_rows` must be the number of rows in `events` now.

## Try it yourself

```
time /ha/dr/restore.sh
pg_restore --list /ha/backups/shop.dump | less
psql -c "select count(*) from events"
```

<details>
<summary>Hint 1 — timing the halves</summary>

`pg_restore` restores a dump in three sections. `pre-data` creates the
tables, `data` loads the rows, and `post-data` builds indexes, constraints
and triggers. `--section` restores just one. Into a fresh server:

```
scratchdb fresh
time pg_restore -O -x -h localhost -p 5433 -d postgres --section=pre-data --section=data /ha/backups/shop.dump
time pg_restore -O -x -h localhost -p 5433 -d postgres --section=post-data /ha/backups/shop.dump
```

</details>

<details>
<summary>Hint 2 — why the indexes cost more than the rows</summary>

Loading rows is a sequential write. Building a B-tree index means reading
the whole table and sorting it by the indexed columns, once per index. Five
indexes on `events` is five full sorts, and the one on `detail` sorts long
random strings.

</details>

<details>
<summary>Solution</summary>

```
time /ha/dr/restore.sh                              # ~10s here
scratchdb fresh
time pg_restore -O -x -h localhost -p 5433 -d postgres --section=pre-data --section=data /ha/backups/shop.dump   # ~2s
time pg_restore -O -x -h localhost -p 5433 -d postgres --section=post-data /ha/backups/shop.dump                 # ~7s
psql -c "select count(*) from events"               # 2000000
```

Record the three figures, then in the runbook set `restore_seconds` to what
you measured plus some margin, `measured_rows: 2000000`, and today's date.

### Reconciling the gap

The old number was not a lie. It was true for 40,000 rows, and nothing in
the runbook said so. The restore has grown about fifty times in rows and
five times in time, and three quarters of the time is index builds, which
grow faster than the data: sorting is more than linear in the row count.

That also says what would help if the number were too big. `pg_restore -j 4`
on a custom-format dump builds independent indexes in parallel. A physical
backup (lesson 4) restores the index files as they are and rebuilds nothing.
Dropping an index nobody reads makes every restore faster as well as every
write.

### Why a drill, and why a schedule

A restore time is a measurement with a date and a size attached. Recording
them next to the number is what lets the next reader see it has gone stale.
Teams that take RTO seriously time a restore on a schedule — monthly, or on
every major growth step — and alert when it crosses a fraction of the
objective, long before it crosses the objective itself.

</details>
