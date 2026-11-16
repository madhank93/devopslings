---
title: "Promote the replica, lose nothing"
---

## The situation

pg1 takes every write. pg2 streams pg1's write-ahead log and replays it: a
hot standby, readable and read-only. Lesson 2 found pg1 on every list of
single points of failure, because when it dies nothing moves the shop to
pg2.

Writing that move is your job. So is a harder question: when the shop told a
customer "order placed", is that order on pg2?

## Your objectives

1. `/ha/failover.sh`, run from ops after pg1 has died, makes pg2 a writable
   primary and moves the app onto it.
2. After it runs, the shop takes orders again.
3. Every order the shop confirmed before pg1 died is on pg2.

You can change anything about how pg1 and pg2 are configured before the
failure. `ALTER SYSTEM` on pg1 followed by `SELECT pg_reload_conf()` keeps a
setting across restarts. The app reads `DB_DSN` from `/ha/app.env` on every
request.

## What you're being graded on

The grader places orders through `www` in a loop and records every one that
was confirmed. Two seconds in, it cuts pg2 off the back network; three
seconds later it kills pg1 and reconnects pg2. Then:

- it runs `/ha/failover.sh`, which must exit 0;
- within 20 seconds an order through `www` must succeed;
- every confirmed order must be in pg2's `orders` table.

Before any of that, an order must complete normally with both servers up.
Afterwards the grader puts pg1 back as the primary and re-clones pg2 from it.

## Try it yourself

```
psql -h pg1 -c "select application_name, state, sync_state from pg_stat_replication"
node cut pg2 back
curl -s --max-time 8 -X POST http://www/orders
node heal pg2 back
```

<details>
<summary>Hint 1 — the two steps of a failover</summary>

`SELECT pg_promote()` on pg2 ends recovery: pg2 stops replaying and starts
accepting writes. That alone helps nobody, since the app is still connecting
to pg1. Promotion and redirection are separate steps, and a failover that
does one without the other leaves the shop down.

</details>

<details>
<summary>Hint 2 — what "confirmed" means</summary>

By default pg1 tells the client "committed" as soon as the commit is on its
own disk. Sending it to pg2 happens afterwards. If pg2 is unreachable for a
few seconds and then pg1 dies, those seconds of confirmed orders existed only
on pg1.

`synchronous_standby_names` makes pg1 wait, at every commit, until a named
standby has the record. The standby's name is its `application_name` in
`pg_stat_replication`.

</details>

<details>
<summary>Hint 3 — what it costs</summary>

With one synchronous standby, the cut-off in the grader's test does not lose
orders. It stops them: commits wait for pg2, the clients time out, and the
shop is unavailable for writes for as long as pg2 is unreachable. That is the
price, and the grader accepts it. An order that was never confirmed was never
promised.

</details>

<details>
<summary>Solution</summary>

Once, on pg1:

```
psql -h pg1 -c "ALTER SYSTEM SET synchronous_standby_names = 'pg2'" -c "SELECT pg_reload_conf()"
```

`/ha/failover.sh`:

```bash
#!/bin/bash
set -eu
psql -h pg2 -qtAc "SELECT pg_promote(wait => true)"
sed -i 's/host=pg1/host=pg2/' /ha/app.env
```

### Asynchronous replication loses what it confirmed

Asynchronous replication gives a replica that is almost always nearly
current. "Almost always" is the problem: the moments when it is behind are
exactly the moments around a failure — a network blip, a busy standby — and
promoting it then silently drops the most recent confirmed writes. Nobody
notices until a customer asks where their order went.

Synchronous replication moves the cost from durability to availability. With
two nodes, one synchronous standby means losing either node stops writes
until someone intervenes. Production setups that want both run three nodes
with `synchronous_standby_names = 'ANY 1 (pg2, pg3)'`: a commit needs any one
of two standbys, so one can be lost without stopping writes, and a promoted
standby is guaranteed to have every confirmed commit — provided you promote
the one that has it.

### What is not handled here

Nothing stops pg1 from coming back as a primary and taking writes from
anything still pointed at it: the shop now has two primaries. Fencing the old
primary — making sure it cannot accept writes before the new one does — is
the part of failover that tools like Patroni exist for. Lesson 7 shows why
they use a quorum to decide, and lesson 10 is what happens when the failback
is left to people.

</details>
