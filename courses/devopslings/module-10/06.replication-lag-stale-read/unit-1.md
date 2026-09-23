---
title: "the order was placed, and the order page says no such order"
---

## The situation

Checkout writes the order to the primary. The order page the customer lands on
a second later reads from the replica, because order pages are most of the read
traffic on `orders` and that is what the replica is there to carry.

Since this morning, the page says the order does not exist.

```
/work/app/checkout.sh
```

The write commits. The read finds nothing. Nothing errored and nothing rolled
back — the primary and the replica simply do not agree yet, and this morning
they stopped agreeing at all.

## Your objectives

- Find out why the replica is not catching up, and put it right
- Make `/work/app/checkout.sh` show the order it just placed even when the
  replica is behind — while the order page still reads from the replica

## What you're being graded on

The grader checks the replica is replaying again, then puts a known delay
between primary and replica — first four seconds, then twelve — and runs
`/work/app/checkout.sh` against each. Both runs must find the order, both must
read it from the replica, and the second must take longer than the first: a
fixed `sleep` is only correct until lag exceeds it. You also fill in
`/work/answers/replication-lag.md`.

<details>
<summary>Hint 1 — ask the replica how far behind it is</summary>

Lag is a number, and there are two of them. On the replica:

```sql
SELECT pg_is_in_recovery()         AS is_standby,
       pg_last_wal_receive_lsn()   AS received,
       pg_last_wal_replay_lsn()    AS replayed,
       pg_last_xact_replay_timestamp() AS last_applied_at,
       pg_wal_lsn_diff(pg_last_wal_receive_lsn(),
                       pg_last_wal_replay_lsn()) AS bytes_behind;
```

Received and replayed are different things. WAL arriving is the network; WAL
being replayed is the replica actually applying it. Run that twice, a few
seconds apart, and watch which of the two moves.

The primary has the other side of the same picture:

```sql
SELECT application_name, state, sent_lsn, write_lsn, flush_lsn, replay_lsn,
       write_lag, flush_lag, replay_lag
  FROM pg_stat_replication;
```

A `state` of `streaming` means the connection is healthy. It says nothing
about whether the standby is applying what it receives.

</details>

<details>
<summary>Hint 2 — a stopped replica is a state, not a failure</summary>

`pg_is_wal_replay_paused()` answers one question, and on this replica it
answers it inconveniently. Replay can be paused deliberately — before a
schema change, to hold a standby at a point in time, to take a copy — and
nothing alerts on it, because from the outside the replica is up, healthy,
streaming, and answering queries. It is answering them from the moment replay
stopped.

`pg_wal_replay_resume()` starts it again, and the backlog applies in order.

</details>

<details>
<summary>Hint 3 — lag is never zero, so the app has to say what it needs</summary>

Resuming replay fixes today. It does not make the replica current: a standby is
always some amount behind, and "some amount" is exactly long enough to land
between a write and the read that follows it.

Sending the read to the primary is correct and costs you the replica. Sleeping
is correct until it isn't.

What is left is to make the read wait for *this* write rather than for a
duration. The primary can name the position of the commit it just made:

```sql
SELECT pg_current_wal_insert_lsn();
```

and the replica can be asked whether it has got that far:

```sql
SELECT pg_last_wal_replay_lsn() >= '0/1A2B3C4'::pg_lsn;
```

Poll that on the replica until it is true, then read. Give the loop a bound —
a page that waits forever on a replica that has stopped again is the outage
you have just finished fixing.

`synchronous_commit = remote_apply` gets you to the same place from the other
end: the `COMMIT` on the primary does not return until a synchronous standby
has applied it. It is a heavier instrument — every write pays the replica's
latency, and a standby that falls over stalls commits unless
`synchronous_standby_names` is set up with that in mind — but for the handful
of writes that are immediately read back, it is the same guarantee bought in
one setting.

</details>

<details>
<summary>Solution</summary>

First, the replica:

```sql
SELECT pg_is_wal_replay_paused();   -- t
SELECT pg_wal_replay_resume();
```

It applies its backlog and the order page starts working. That is today's
incident, and it is not the fix.

Then the read-your-writes path, in `/work/app/checkout.sh`:

```bash
id=$(primary -c "INSERT INTO orders (...) VALUES (...) RETURNING id")
lsn=$(primary -c "SELECT pg_current_wal_insert_lsn()")

deadline=$(( $(date +%s) + 30 ))
until [ "$(replica -c "SELECT pg_last_wal_replay_lsn() >= '$lsn'::pg_lsn")" = t ]; do
  [ "$(date +%s)" -lt "$deadline" ] || break
  sleep 0.2
done

status=$(replica -c "SELECT status FROM orders WHERE reference = '$ref'")
```

The page reads the replica exactly as before. The only thing that changed is
that it knows which moment it needs the replica to have reached, and waits for
that moment rather than for a guess.

### The part worth remembering

**Replication lag is not an error state.** A streaming replica is behind by
design, and the interesting number is not "is it replicating" but "how far
behind is it right now". `pg_stat_replication.replay_lag` on the primary and
`pg_last_wal_replay_lsn()` on the standby are the two ends of it. Alert on the
gap in bytes or seconds, not on the connection.

**"Streaming" and "applying" are different health checks.** This replica was
connected, healthy, and serving queries the entire time, which is why nothing
paged. Replay was stopped. Any monitoring that checks the replication
connection and not the replay position reports green through exactly this
incident.

**Read-your-writes is a property of a request, not of a database.** Most reads
do not care about a write that happened 200ms ago; the one immediately after a
checkout does. Sending everything to the primary is a real fix that hands back
every bit of capacity the replica was giving you. Naming the write's position
and waiting for it — an LSN, a session token, `remote_apply` on the writes that
need it — buys correctness only where correctness was actually at stake.

**A wait on a replica needs a bound and a fallback.** The loop above gives up
after thirty seconds, and a page that gives up must then do something: read the
primary for that one request, or tell the customer the page is not ready yet.
An unbounded wait on a component that can pause is how one stalled replica
becomes a stalled application — the same queueing that made a blocked migration
into a table-wide outage a lesson ago.

</details>
