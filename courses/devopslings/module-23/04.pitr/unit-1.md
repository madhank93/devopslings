---
title: "Recover to the moment before the DELETE"
---

## The situation

pg1 archives every finished WAL segment to `/ha/archive/wal/`, and a base
backup was taken this morning into `/ha/archive/base/`. After that:

1. the morning's orders came in;
2. a cleanup job ran `DELETE` on `orders` with the wrong cutoff, and nearly
   every order was gone;
3. the shop kept trading, and customers placed 40 more orders.

The incident report is in `/ha/dr/INCIDENT.txt`. Nobody wrote down the exact
time of the `DELETE`.

## Your objectives

1. Every deleted order is back in pg1's `orders`, with its original `id`.
2. The 40 orders placed after the `DELETE` are still there.
3. pg1 stays the primary and stays open for orders while you work.

## What you're being graded on

The grader reads pg1's `orders`:

- every order placed after the `DELETE` is present;
- every order deleted by it is back, exactly once, with its old `id` and
  `placed_at` — including the ones placed after the base backup was taken.

## Try it yourself

```
ls /ha/archive/wal/ /ha/archive/base/
pg_waldump -p /ha/archive/wal <segment> | less
scratchdb fresh            # an empty server is not what you need here, though
```

ops has the Postgres 17 server binaries. `gosu postgres pg_ctl ...` runs them
as the `postgres` user, which a data directory needs.

<details>
<summary>Hint 1 — why not just restore the base backup</summary>

The base backup is from before the morning's orders. Restoring it gives you
the old orders and none of the morning's. To get those you replay the WAL
archive on top of the base backup, and stop just before the `DELETE`
commits. That is point-in-time recovery.

</details>

<details>
<summary>Hint 2 — finding the moment</summary>

`pg_waldump` prints every WAL record: its transaction id (`tx:`), and for a
heap change its kind (`INSERT`, `DELETE`, ...). A transaction that deleted a
thousand rows is hard to miss. Its `COMMIT` record carries a timestamp, too.

Recovery can stop at a time (`recovery_target_time`) or at a transaction
(`recovery_target_xid`). With `recovery_target_inclusive = off` it stops just
*before* that transaction, which is exactly "before the DELETE".

</details>

<details>
<summary>Hint 3 — where to recover</summary>

Not on pg1. Recovering pg1 itself rewinds the 40 orders placed afterwards.
Recover a copy on the side: unpack the base backup into a new directory in
ops, add `restore_command` and the target to its `postgresql.auto.conf`,
create `recovery.signal`, start it on another port. Then copy the rows you
need from it into pg1.

The base backup carries pg1's settings, including `archive_command`. Turn
`archive_mode` off in the copy, or the recovered server will write a new
timeline into pg1's archive.

</details>

<details>
<summary>Solution</summary>

Find the `DELETE`:

```
cd /ha/archive/wal
for f in 0000000*[0-9A-F]; do pg_waldump -p . $f 2>/dev/null; done \
  | grep 'desc: DELETE' | grep -o 'tx: *[0-9]*' | sort | uniq -c | sort -rn | head -3
```

Recover a copy to just before it:

```
d=/var/lib/pitr; mkdir -p $d
tar -xzf /ha/archive/base/base.tar.gz -C $d
cat >> $d/postgresql.auto.conf <<CONF
archive_mode = off
restore_command = 'cp /ha/archive/wal/%f %p'
recovery_target_xid = '<xid>'
recovery_target_inclusive = off
recovery_target_action = promote
port = 5434
listen_addresses = 'localhost'
CONF
touch $d/recovery.signal; chown -R postgres:postgres $d; chmod 700 $d
gosu postgres pg_ctl -D $d -l $d/log -w start
grep 'recovery stopping' $d/log
```

Copy the deleted rows back:

```
psql -h localhost -p 5434 -c "\copy (SELECT * FROM orders) TO '/root/deleted.csv' CSV"
psql -h pg1 <<'SQL'
CREATE TEMP TABLE restored (LIKE orders);
\copy restored FROM '/root/deleted.csv' CSV
INSERT INTO orders SELECT * FROM restored ON CONFLICT (id) DO NOTHING;
SQL
```

### Why the base backup is not enough

A base backup is a copy of the data files at one moment. The WAL archive is
every change after it. Recovery replays the second on top of the first, and
can stop anywhere along the way. Without the archive your recovery point is
the time of the last base backup; with it, it is any transaction you choose.

### Why not rewind pg1

Point-in-time recovery rewinds *everything* to that point. Here, that
includes 40 orders that customers placed and were told about. Recovering on
the side and copying back only the damaged rows is slower and more careful,
and it is the only option that loses nothing. When the damage is spread
across many tables, the same idea becomes a script that diffs the recovered
copy against production.

`ON CONFLICT (id) DO NOTHING` makes the copy safe to re-run: an order that
was never deleted, or was already copied back, is left alone.

</details>
