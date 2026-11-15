---
title: "Capacity planning"
---

## The situation

Checkout peaks at 240 requests a second today, and marketing's forecast
(`/ha/sre/capacity/forecast.txt`) has it at 600 within a year. The proposal
on the table (`proposal.txt`) is arithmetic on the node count: 2.5 times the
traffic, 2.5 times the web nodes, order three more.

The capacity dashboard agrees that the web nodes are the thing to watch:
they are the busiest thing on it. But every checkout request holds three
things while it runs: CPU on a web node, a connection to the Postgres
primary, and a call in flight to the payment provider. Each has a limit
(`fleet.txt`), and adding web nodes raises only one of them.

`/ha/sre/capacity/loadtest.csv` is a load test at today's peak: one row per
request, with how long it spent on each.

## Your objectives

Write the plan in `/ha/answers/capacity.txt`:

1. The headroom you plan to: the most of any resource the forecast peak may
   use.
2. For each resource in `fleet.txt`: what one request costs it, how much of
   it the peak keeps busy at once, and what the plan provides.
3. Which resource reaches the headroom line first as traffic grows from
   today, and at what request rate.

## What you're being graded on

- the headroom is a real ceiling, between 50% and 85%;
- each per-request cost is the mean time that resource is held, from the
  load test, and each "in use" follows from it by Little's Law;
- the web node count is derived from busy cores at your headroom (one spare
  node is fine), and the other two resources are planned to at least what
  the peak needs at that headroom;
- the first resource to saturate, and when, is named correctly.

## Try it yourself

Little's Law: the number of things in a system at once is the rate they
arrive times how long each stays. Apply it once per resource, not once per
request.

<details>
<summary>Hint 1 — which time</summary>

A request takes about 300 ms end to end, but it does not hold a CPU for
300 ms: most of that it is waiting on the database and the provider, with
the CPU free for other requests. Each resource is held for its own column's
time. And it is the mean, not the median or the p99: Little's Law is about
averages over time, and the slow tail is part of the average.

</details>

<details>
<summary>Hint 2 — what runs out first</summary>

For each resource, the traffic at which it reaches your headroom is
`headroom x capacity today / time held`. Compare the three. The one on the
dashboard is not the smallest.

</details>

<details>
<summary>Solution</summary>

Means from the load test (yours differ a little; the data is generated per
reset): about 16 ms of CPU, 95 ms holding a connection, 180 ms at the
provider.

```
headroom: 70%
peak: 600
resource: web_cpu | 15.9 ms | 9.52 cores | 4 nodes
resource: db_connections | 94.9 ms | 57.0 connections | 90 connections
resource: payment_concurrency | 178.9 ms | 107.3 calls | 154 calls
saturates_first: payment_concurrency
saturates_at: 313
```

```bash
python3 - <<'PY'
import csv, statistics
rows = list(csv.DictReader(open("/ha/sre/capacity/loadtest.csv")))
for c in ("cpu_ms", "db_ms", "provider_ms"):
    m = statistics.fmean(float(r[c]) for r in rows)
    print(f"{c}: mean {m:.1f} ms, at 600 req/s {600 * m / 1000:.1f} in use")
PY
```

### The web tier

600 req/s x 0.016 s = 9.6 cores busy. At 70% of 4 vCPU a node gives 2.8
usable cores, so 4 nodes, or 5 to survive losing one at peak. The proposal
had the right instinct for the wrong reason: today's nodes are under half
busy, so node count does not scale one-for-one with traffic.

### The wall

600 x 0.18 s = 107 calls in flight, against a contract of 80. At 70% the
provider has to agree to about 155. It reaches the 70% line at roughly
310 req/s, before the web tier does at about 350, and months before the
forecast peak. Every web node the proposal orders makes this worse, not
better: more capacity to send calls that the provider then rejects with
429s.

That is the point of planning per resource. A plan that scales the
dimension it can see runs into the one it did not size.

### The database

95 ms x 600 = 57 connections, 63% of the 90 the app has. Inside 70% today,
and the next wall after the provider. Worth noting: each new web node opens
its own connection pool, so "add nodes" moves connections the wrong way.

</details>
