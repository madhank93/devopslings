---
title: "Kill the toil"
---

## The situation

`/ha/sre/runbook-weekly.md` is the on-call's Monday: delete carts nobody has
touched for a week, move orders older than 90 days to the archive, and post
the counts in the ops channel. It takes about forty minutes with the
interruptions, it has been done by hand every week for two years, and twice
somebody pasted the DELETE before the INSERT.

That is toil in the Google SRE book's sense: manual, repetitive,
automatable, and it grows with the shop.

The shop already has somewhere to run background jobs: `/ha/app/scheduler.sh`
runs on **both** web1 and web2, restarted a second after it exits and at once
when the file changes (module 22's leader-election lesson used it). web1 and
web2 have `python3` with `psycopg` and `etcdctl`, but not `psql`. The
database's connection string is `DB_DSN` in `/ha/app.env`.

## Your objectives

1. Write `/ha/sre/weekly-cleanup`, an executable that does the runbook's two
   steps.
2. Make each run append one line to `/ha/sre/toil.log` with what that run
   changed and how long it took:

   ```
   2026-11-16T09:00:00 node=web1 carts_deleted=37 orders_archived=58 seconds=0.04
   ```

3. Schedule it from `/ha/app/scheduler.sh`. In the sandbox a week is 15
   seconds, so it has to run at least that often.

## What you're being graded on

The grader seeds a fresh week of leftovers three times:

- runs the job once on web1: the right rows go, the right rows stay, and the
  report matches what changed;
- runs it on web1 and web2 at the same moment: still exactly right, and both
  runs exit 0;
- runs nothing: the scheduler must clean the week within 45 seconds.

## Try it yourself

```
psql -c "SELECT count(*) FROM toil.carts WHERE touched_at < now() - interval '7 days'"
docker exec devopslings-ha-web1 /ha/sre/weekly-cleanup; tail -1 /ha/sre/toil.log
psql -c "SELECT count(*), count(DISTINCT id) FROM toil.orders_archive"
```

<details>
<summary>Hint 1 — the runbook is written for one person</summary>

"Copy the old orders, then delete them" is safe when one person does it.
Run it on two machines at the same moment and both copy the same rows
before either deletes them. A scheduler on two nodes will do exactly that,
every week.

</details>

<details>
<summary>Hint 2 — two ways out</summary>

Either only one copy runs (a lock: `pg_try_advisory_lock`, or module 22's
etcd leader), or the work is safe to run twice. Postgres can move rows in
one statement: a `DELETE ... RETURNING *` inside a `WITH`, feeding an
`INSERT`. A second copy blocks on the rows the first is deleting, and then
finds nothing left.

</details>

<details>
<summary>Solution</summary>

```python
#!/usr/bin/env python3
import socket, time
import psycopg

t0 = time.monotonic()
dsn = next(l.split("=", 1)[1].strip() for l in open("/ha/app.env") if l.startswith("DB_DSN="))
with psycopg.connect(dsn, autocommit=True) as c:
    carts = c.execute("DELETE FROM toil.carts WHERE touched_at < now() - interval '7 days'").rowcount
    orders = c.execute(
        "WITH moved AS (DELETE FROM toil.orders WHERE placed_at < now() - interval '90 days' RETURNING *) "
        "INSERT INTO toil.orders_archive SELECT * FROM moved").rowcount
with open("/ha/sre/toil.log", "a") as f:
    f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} node={socket.gethostname()} "
            f"carts_deleted={carts} orders_archived={orders} seconds={time.monotonic() - t0:.2f}\n")
```

```bash
#!/bin/bash
while :; do
  /ha/sre/weekly-cleanup || echo "weekly-cleanup failed with $?"
  sleep 10
done
```

### What "killed" means

A script someone still has to remember to run is a faster version of the
same toil. The job is only gone from the rota when it runs without anyone,
says what it did where people already look, and cannot make things worse
when it runs at an unexpected moment, including twice.

### Measure it, both ways

The `seconds=` field is the other half of the business case. Forty minutes a
week is about 35 hours a year of an engineer's time; the job takes a fraction
of a second. The counts matter as much: when `orders_archived` is suddenly
ten times the usual, the log is where somebody notices, and that is the
check the person running it by hand used to do without thinking.

</details>
