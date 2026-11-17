---
title: "Eighty connections, fewer tickets"
---

## The situation

The box office sells seats for four shows. Every booking runs one statement,
`SELECT book(show)`, which locks that show's row, rebuilds the seat map, and
commits. The sales dashboard refreshes alongside, and its query is pure CPU.
The app reaches Postgres through pgbouncer, as the `boxoffice` database, from
80 connections across its instances. It waits half a second for a booking; past
that, the customer gets "something went wrong, try again".

At the last on-sale, bookings sat in pgbouncer waiting for a server connection,
so someone raised the pool from 20 to 80: one server connection per app
connection, nothing waits. Run this on-sale and see what that bought:

```
bash <lesson>/files/load.sh
```

```
{"pool_size": 80, "bookings_per_s": 571, "booking_p99_ms": 1097, "booking_errors": 493, "max_ms": 3086}
```

(Your numbers will differ; the shape will not.) About one booking in twenty
misses the deadline, and the box office sells fewer seats a second than it does
with a smaller pool.

The pool lives on the `boxoffice` line of pgbouncer's config:

```
docker compose exec pgbouncer vi /etc/pgbouncer/pgbouncer.ini
```

```
boxoffice = host=primary port=5432 dbname=boxoffice auth_user=postgres pool_size=80
```

Apply an edit, and look at the pool while a run is going, on pgbouncer's admin
console:

```
docker compose exec -e PGPASSWORD=devopslings primary psql -h pgbouncer -U postgres pgbouncer -c RELOAD
docker compose exec -e PGPASSWORD=devopslings primary psql -h pgbouncer -U postgres pgbouncer -c 'SHOW POOLS'
```

`cl_waiting` is app connections waiting for a server connection; `sv_active`
is server connections running a query.

## Why more connections can sell fewer seats

A server connection is a Postgres backend, a process. The machine has a fixed
number of cores. With 80 backends all running, the scheduler gives each a slice
of a core in turn, and every query takes longer in wall-clock time than it
needs in CPU time.

For most queries that costs latency and nothing else. For a booking it costs
more: the booking holds its show's row lock from the `UPDATE` to the commit.
If the scheduler takes the core away while it holds that lock, every other
booking for that show waits for a process that is not even running. The lock
is held longer, so fewer bookings get through it a second, so more bookings
pile up behind it — and those, too, are backends competing for the cores.

A small pool moves the waiting. The extra app connections wait in pgbouncer,
which costs nothing but time in a queue, and the few backends Postgres runs
each get a core, finish fast, and release their locks fast. Too small a pool,
though, and cores sit idle while bookings queue: that is the problem the last
on-sale had.

There is a pool size between those that does best, and it depends on the
cores, the workload and the locks. Rules of thumb exist (Postgres's own wiki
suggests about twice the core count to start from), but the answer for this
machine and this workload comes from measuring it.

## Your objectives

1. Run the on-sale at several pool sizes and append each line `load.sh`
   prints to `sandboxes/db-stack/answers/pool-sizing.txt`. At least four sizes,
   with at least one at 8 or fewer and one at 48 or more.
2. Set the `boxoffice` pool to the size your table says is best, in
   `pgbouncer.ini`, and reload pgbouncer.

## What you're being graded on

The check reads your table and the running pool, which must be one of the
sizes you measured and must match the file. Then it runs the on-sale twice,
15 seconds each, back to back: once through `boxoffice_before`, a second
pgbouncer entry the init left at the original pool of 80, and once through
yours. Yours must sell at least 90% as many seats a second as the original,
with **no** booking past the 500ms deadline and a booking p99 at most half the
original's.

<details>
<summary>Hint 1 — reading the table</summary>

Two columns move in opposite directions as the pool shrinks. The rate rises
until the cores are busy, then levels off or falls. The p99 falls until
bookings start queueing in pgbouncer, then rises again. You want the size
where the rate has stopped rising and the p99 has not started to.

</details>

<details>
<summary>Hint 2 — a run that disagrees</summary>

One 15-second run on a laptop is noisy. If two neighbouring sizes look the
same, run each again before you choose; the check runs its own measurement,
and a size on the edge of the cliff can fall off it.

</details>

<details>
<summary>Solution</summary>

Measure:

```
for n in 4 8 12 16 24 48; do
  docker compose exec pgbouncer sed -i "s/^\(boxoffice *=.*pool_size=\)[0-9]*/\1$n/" /etc/pgbouncer/pgbouncer.ini
  docker compose exec -e PGPASSWORD=devopslings primary psql -h pgbouncer -U postgres pgbouncer -c RELOAD
  bash <lesson>/files/load.sh >> answers/pool-sizing.txt
done
```

On an 11-core machine the table looked like this:

```
{"pool_size": 4,  "bookings_per_s": 319, "booking_p99_ms": 228, "booking_errors": 0, ...}
{"pool_size": 8,  "bookings_per_s": 475, "booking_p99_ms": 167, "booking_errors": 0, ...}
{"pool_size": 12, "bookings_per_s": 610, "booking_p99_ms": 119, "booking_errors": 0, ...}
{"pool_size": 16, "bookings_per_s": 631, "booking_p99_ms": 138, "booking_errors": 0, ...}
{"pool_size": 24, "bookings_per_s": 657, "booking_p99_ms": 189, "booking_errors": 0, ...}
{"pool_size": 48, "bookings_per_s": 518, "booking_p99_ms": 522, "booking_errors": 9, ...}
```

The rate levels off from about 12, and the p99 is lowest between 12 and 16.
Set the `boxoffice` line to `pool_size=16` (or whatever your table says) and
reload. Eighty app connections now share 16 server connections; the rest wait
in pgbouncer for a few milliseconds instead of inside Postgres for hundreds.

### In production

- Size the pool per database **and** count all of them: every pgbouncer, every
  service with its own pool, and every admin session share one
  `max_connections`, and one set of cores.
- `SHOW POOLS` with a steady `cl_waiting` and idle CPU on the database means
  the pool is too small. Busy CPU, long lock waits in `pg_stat_activity`, and
  a growing p99 with a large `sv_active` means it is too large.
- Re-measure when the workload changes. The best size here came from a lock
  held during CPU work; a workload waiting on disk or the network would want
  more connections, because a backend waiting on I/O is not using its core.

</details>
