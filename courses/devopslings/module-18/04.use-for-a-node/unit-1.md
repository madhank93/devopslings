---
title: "db is slow, and its CPU is idle"
---

## The situation

shop's `/cart` and `/orders/:id` pages are slow, and some fail. Both read from
db. The team's db dashboard shows CPU and memory, and both look fine: CPU at a
few percent, memory flat.

```
promq 'rate(process_cpu_seconds_total{job="db"}[30s])'
promq 'process_resident_memory_bytes{job="db"}'
```

CPU is the resource people graph first because it is easy to graph. A process
waiting for something uses no CPU while it waits, so CPU cannot show that kind
of slowness.

## The USE method

Brendan Gregg's USE method is a checklist instead of a guess. For **every**
resource a system has, check three things:

- **Utilisation**: how much of its capacity is in use, as a fraction from 0
  to 1. At 100% the resource is busy all the time.
- **Saturation**: work that the resource cannot take yet, so it waits in a
  queue. Saturation keeps growing with load after utilisation has reached
  100%.
- **Errors**: work the resource refused or failed.

"Every resource" includes the hardware (CPU, memory, disks, network) and also
the software resources that have a fixed number of slots: thread pools,
connection pools, file descriptors, locks. Many outages happen in those
software resources.

Start with what db exposes:

```
curl -s db:9101/metrics
```

## Your objectives

Find db's saturated resource, then write one PromQL expression per file for
it:

| File | What it should measure |
|---|---|
| `/obs/queries/use-utilisation.promql` | the resource's utilisation, 0 to 1 |
| `/obs/queries/use-saturation.promql` | work queued for it |
| `/obs/queries/use-errors.promql` | how often it refuses work, per second |

Test each one with `promq "$(cat /obs/queries/use-saturation.promql)"`.
Use windows of 30 seconds or less (`[30s]`), because the check measures each
state for about half a minute.

## What you're being graded on

The check evaluates your three queries twice: once with db healthy, and once
with db saturated under extra load. Each query has to tell the two states
apart the way its letter says:

- utilisation stays between 0 and 1, and is high only when db is saturated
- saturation is about zero when healthy, and grows with the number of queries
  waiting
- errors is about zero when healthy, and positive while db refuses queries

<details>
<summary>Hint 1 — which resource</summary>

db exposes the usual process metrics, which every Python client exports, and
a group of `db_pool_*` metrics. A connection pool has a fixed number of
connections. A query borrows one, and gives it back when it finishes. Compare
`db_pool_connections_in_use` with `db_pool_connections_max`.

</details>

<details>
<summary>Hint 2 — utilisation and saturation are different numbers</summary>

When every connection is in use, utilisation is 1, and it stays 1 when the
load doubles. The queries that could not get a connection are waiting, and
that number grows with the load: `db_pool_waiting_queries`.

Gauges are sampled every scrape, so `avg_over_time(...[30s])` gives a steadier
reading than one sample. The refusals are a counter; take its `rate()`.

</details>

<details>
<summary>Solution</summary>

```
# use-utilisation.promql
avg_over_time(db_pool_connections_in_use[30s]) / db_pool_connections_max

# use-saturation.promql
avg_over_time(db_pool_waiting_queries[30s])

# use-errors.promql
rate(db_pool_acquire_timeouts_total[30s])
```

db has two connections. A migration holds a lock that every query waits on,
and each query holds its connection while it waits. So both connections are
always checked out (utilisation 1), the next queries queue for one
(saturation), and after a second in the queue they are refused with a 503
(errors). None of that uses CPU.

The fix is a separate decision: end the migration, make queries stop holding
connections while they wait, or add connections. Adding connections to a
database that is waiting on a lock only moves the queue from the pool to the
lock. USE finds the bottleneck; it does not decide what to do about it.

### The ways this goes wrong

- **CPU and memory only.** They are the resources a dashboard graphs by
  default. A process that waits, for a lock, a pool, a disk or the network,
  uses no CPU.
- **Utilisation as saturation.** `db_pool_connections_in_use` stops at the
  pool size. It looks the same at twice the load, so it cannot tell you how
  far over capacity db is. The queue length can.
- **A raw count as utilisation.** "2" means nothing until you know there are
  two connections in total. Divide by the capacity.
- **A raw counter as errors.** `db_pool_acquire_timeouts_total` is every
  refusal since db started. It stays high after the problem has ended.
  `rate()` shows what is happening now.

</details>
