---
title: "billing says the workers did 2,000 jobs, the graph says minus 800"
---

## The situation

Two queue workers, `worker-a` and `worker-b`, each count finished jobs in
`worker_jobs_processed_total`. The capacity dashboard's panel "jobs processed
in the last 5 minutes" uses this query, in `/obs/queries/jobs-last-5m.promql`:

```
sum(worker_jobs_processed_total) - sum(worker_jobs_processed_total offset 5m)
```

It matches billing most of the time. After a deploy it shows a number that
never happened, sometimes a negative one. Billing keeps its own record: each
worker appends one line, with a timestamp, to `/obs/run/ledger-a.log` or
`ledger-b.log` for every job it finishes. The ledger survives restarts.

```
promq "$(cat /obs/queries/jobs-last-5m.promql)"
awk -v t=$(( $(date +%s) - 300 )) '$1 > t' /obs/run/ledger-*.log | wc -l
```

## What a counter's value means

A counter counts since its **process started**. When the process restarts,
the counter starts again at 0. The raw value, 4,312, says nothing on its own,
and the difference between two raw values is only right if no restart
happened between them.

`rate()` and `increase()` are built for that. They look at every sample in
the window, and when the value goes **down**, they take it as a restart: the
count continued from zero, so they add the new value instead of subtracting.

- `rate(c[5m])`: average increase **per second** over the last 5 minutes
- `increase(c[5m])`: total increase over the last 5 minutes, which is
  `rate × 300`

Both work on one series at a time. The order matters when you add series
together.

## Your objectives

Rewrite `/obs/queries/jobs-last-5m.promql` so it returns one number: jobs
processed by all workers in the last 5 minutes, correct across a worker
restart.

## What you're being graded on

The check restarts `worker-a`, waits for a few scrapes, then runs your query
and compares it with the number of ledger lines from the last 5 minutes.
They have to agree within about 8%. `increase()` estimates a little from the
samples at the edges of the window, so an exact match is not expected.

<details>
<summary>Hint 1</summary>

`increase(worker_jobs_processed_total[5m])` returns one series per worker,
each handling its own restarts. Then add them up.

</details>

<details>
<summary>Hint 2 — the order of sum and increase</summary>

`increase(sum(worker_jobs_processed_total)[5m:])` takes the sum first. When
worker-a restarts, the sum drops by worker-a's whole count. To `increase()`
that is a reset of the sum, so it counts everything worker-b had already done
as new. Take the rate of each series first, then sum.

</details>

<details>
<summary>Solution</summary>

```
sum(increase(worker_jobs_processed_total[5m]))
```

`increase()` handles each worker's reset in that worker's own series, and
`sum` adds the results. This rule applies to every counter: **rate first,
then aggregate.** `sum(rate(...))`, never `rate(sum(...))`.

Prometheus loses the jobs a worker finished after its last scrape and
before it died, a few seconds' worth, and `increase()` extrapolates a little
at the window's edges. So the panel is close to billing, not equal to it.
For metrics, close is the goal. A number that has to be exact, like what a
customer is billed, belongs in a ledger like this one, and metrics should
not be used to produce it.

### The ways this goes wrong

- **Raw arithmetic on counters**: `x - x offset 5m`, or
  `max_over_time(x[5m]) - min_over_time(x[5m])`. Right until the first
  restart.
- **`rate()` where a count was wanted.** It is per second, 300 times smaller
  than the count over 5 minutes.
- **`increase(sum(...))`**: the sum drops when any one process restarts, and
  the drop is read as a reset of everything.
- **No `sum`**: one series per worker, which a single-number panel shows
  only the first of.

</details>
