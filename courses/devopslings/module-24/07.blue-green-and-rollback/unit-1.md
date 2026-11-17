---
title: "Blue/green and rollback"
---

## The situation

Two copies of the shop, and the load balancer chooses one:

```
www ──> default_backend green
          blue  = web1, running v1
          green = web2, running v2      <- live since 09:40
```

v2 is bad, and it is your call to roll back. Blue is still up, still running
v1. Rolling back should take seconds.

Except v2 came with a migration (`/ha/sre/migrations/002-v2.sql`), and it has
already run:

```sql
ALTER TABLE bg.orders RENAME COLUMN placed_at TO created_at;
ALTER TABLE bg.orders ADD COLUMN currency text NOT NULL DEFAULT 'EUR';
ALTER TABLE bg.orders ALTER COLUMN currency DROP DEFAULT;
```

Ask blue what it thinks of that: `curl -s http://web1:8080/checkout`.

The builds are in `/ha/deploy/builds/` (`v1.py`, `v2.py`). They are what
shipped, and you cannot change them. `/ha/sre/deploy <node> <build>` is the
team's deploy tool; it builds, pushes and rolls out, and takes over a minute.

## Your objectives

1. Rewrite `/ha/sre/migrations/002-v2.sql` so that v1 and v2 can both run on
   the schema it leaves, in either order.
2. Write `/ha/sre/rollback`: when it returns, `www` sends everyone to v1.

## What you're being graded on

The grader rebuilds v1's schema, applies your migration, puts
`/ha/sre/haproxy-green.cfg` in place as `/ha/haproxy.cfg` (v2 live), and
then, with customers checking out the whole time:

- runs `/ha/sre/rollback`. It must finish within 60 seconds; from 5 seconds
  after it returns, every request must be answered by v1, successfully,
  through both lb1 and lb2, and no request may go unanswered while it runs;
- rolls forward to green again: v2 must work on the orders v1 wrote in the
  meantime, and its `created_at` must be when each order was placed.

## Try it yourself

```
curl -s http://web1:8080/checkout; echo
curl -s http://web2:8080/checkout; echo
psql -c '\d bg.orders'
gapwatch 30 http://www/checkout & /ha/sre/rollback; wait
```

<details>
<summary>Hint 1 — the fast path already exists</summary>

Blue is running v1 right now. A rollback that rebuilds v1 is a deploy, with
a deploy's duration. Moving traffic is one line in `/ha/haproxy.cfg`, which
both load balancers reload within a second.

</details>

<details>
<summary>Hint 2 — expand, then contract</summary>

A migration that ships with a new version can only add things while the old
version may still run: new columns with defaults, never a rename or a drop.
Removing what v1 used comes in a later release, once nobody can roll back to
v1 any more.

For `created_at`, v2 reads a column v1 never writes. Postgres can compute a
column from another one.

</details>

<details>
<summary>Solution</summary>

```sql
ALTER TABLE bg.orders ADD COLUMN currency text NOT NULL DEFAULT 'EUR';
ALTER TABLE bg.orders ADD COLUMN created_at timestamptz GENERATED ALWAYS AS (placed_at) STORED;
```

```bash
#!/bin/bash
set -eu
sed -i -E 's/^([[:space:]]*default_backend[[:space:]]+)green/\1blue/' /ha/haproxy.cfg
for lb in lb1 lb2; do
  for _ in $(seq 40); do
    curl -s -o /dev/null -D - --max-time 2 "http://$lb/checkout" | grep -qi '^x-build: v1' && break
    sleep 0.25
  done
done
```

### Both directions

The original migration broke the backward direction twice: v1 reads
`placed_at`, which was renamed away, and v1's inserts do not set `currency`,
which lost its default. Either alone is enough to make blue useless.

The forward direction is subtler. After a rollback, v1 writes orders for a
while. Then v2 is fixed and goes out again, and reads those orders. If
`currency` were nullable with no default, v2 would crash on the first one:
the fix has to hold for rows written by the version that does not know the
column exists.

A generated column makes `created_at` right by construction. A plain column
with a default works too, as long as the existing rows are backfilled from
`placed_at`.

### Contract later

The rename v2 wanted is still possible: once v2 has run long enough that
nobody would roll back to v1, a later migration moves readers to
`created_at` and drops `placed_at`. Expand, migrate, contract, each in its
own release. Module 10's zero-downtime migration is the same idea on one
table, without the rollback.

### Why the load balancer config, not the runtime API

`set server` on HAProxy's admin socket is instant too, but it changes one
process. lb2 would still send customers to green, and the moment the VIP
fails over, they are on v2 again. And anything the runtime API changed is
gone on the next reload.

</details>
