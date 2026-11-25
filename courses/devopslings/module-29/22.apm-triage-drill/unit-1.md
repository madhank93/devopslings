---
title: "checkout's p99 doubled overnight"
---

## The situation

checkout takes orders, about thirty a second. For each one it validates
the email, asks **pricing** for a quote, and records the order with
**ledger**. pricing asks ledger for the prices of the order's items.

```
checkout ──> pricing (fulfil:8080) ──> ledger
    └───────────────────────────────> ledger
```

(pricing runs in the `fulfil` container; its spans and profiles say
`pricing`.) The p99 budget is 150ms, and checkout is well over it. The
on-call's proposal is to restart checkout, and if that does not hold, run
two of it.

The cause is one of five, drawn at random each time you start this drill:

- an **N+1** in pricing
- ledger's **connection pool** shrunk to one
- a **CPU-hot regex** in checkout
- a **retry storm** on a timed-out downstream
- a **lock held across an HTTP call**

Everything the module used is already wired up: every service sends spans
to the Collector, which feeds Tempo and turns them into span metrics (with
exemplars) and a service graph that Prometheus scrapes as job `spans`.
Every service sends CPU profiles to Pyroscope (`http://pyroscope:4040`, and
Grafana's Pyroscope datasource), linked to the spans that were running. The
source is in `/obs/apps/`; saving a file restarts that service.

## The triage order

Work from the outside in, and write down what each step showed:

1. **Service map.** Which edge got slow, or got busier than the order rate
   explains? Per edge, not per service: a service's latency includes its
   callees'.
   `histogram_quantile(0.99, sum by (client, server, le) (rate(traces_service_graph_request_server_seconds_bucket[1m])))`
   and the same `request_total` rates.
2. **Span metrics.** Within the service the map points at, which operation:
   rate, errors and duration per span name.
3. **An exemplar trace.** One slow order, opened. Where does its time go:
   inside a child span, between child spans, in many small spans?
4. **A profile.** For the service where the time is spent: is it CPU, and in
   which function, or is the process idle and waiting?

Then fix the cause in the code where it lives, and decide what would have
paged someone before customers noticed.

## Your objectives

1. Fix the cause where it lives. checkout's p99 goes back under 150ms.
2. Fill in `/obs/answers/triage.md`: the cause and the service it lives in,
   what each of the four steps showed, the ID of a slow trace you read, and a
   detection query over the span metrics or service graph with the value at
   which it should page.

## What you're being graded on

- `cause` and `service` match this run's seeded cause
- over the 30 seconds after your last change, checkout's p99 is under
  150ms, and the cause itself is gone, not diluted
- `exemplar` is a checkout trace in Tempo that was over budget
- each evidence line says what the step showed; for a CPU cause, the
  profile names the function
- `detect` runs in Prometheus, uses the span metrics or service graph,
  returns data, and `threshold` is a number

<details>
<summary>Hint 1 — reading the shape of a slow trace</summary>

Many short client spans in a row; one long client span; a long gap with no
child span at all; the same call repeated with errors. Each shape points at
a different one of the five.

</details>

<details>
<summary>Hint 2 — busy or waiting</summary>

A flame graph only shows CPU. If a service's trace time is high and its
profile is flat, its threads are waiting: on a pool, a lock, or another
service.

</details>

<details>
<summary>Solution</summary>

Each cause, the trail it leaves, and the fix:

| Cause | Service map | Trace | Profile | Fix |
|---|---|---|---|---|
| N+1 | pricing → ledger at ~10x the order rate | a dozen `GET /prices` per quote | pricing idle | one `GET /prices?skus=a,b,c` per quote |
| pool | every → ledger edge slow | ledger server spans long, its work short | ledger idle | pool back to 16 |
| regex | edges fast | time inside `validate email` | checkout hot in `fullmatch` | a linear regex: `[^@\s]+@[^@\s]+` |
| retry storm | checkout → pricing rate ≫ orders, failing | repeated quote calls with timeouts | pricing busy | timeout above pricing's latency, one retry |
| lock | checkout → ledger fast | gap before the ledger call | checkout idle | call ledger without holding `LEDGER` |

A detection signal that catches all five early is checkout's own p99 from
span metrics:

```
detect: histogram_quantile(0.99, sum by (le) (rate(traces_span_metrics_duration_milliseconds_bucket{service_name="checkout",span_name="POST /checkout"}[1m])))
threshold: 150
```

and a more specific one for the cause you found, such as the ratio of
pricing's request rate to checkout's for a retry storm.

### The ways this goes wrong

- **Restarting checkout, or running two.** The bug is in the code; a
  restart runs the same code, and a second copy doubles the pressure on
  whatever was waiting.
- **The slowest service.** checkout is always the slowest; it waits for
  everything. The edge tells you where to look.
- **Fixing a symptom.** Raising pricing's worker count during a retry
  storm, or adding a cache in front of the N+1, makes the graph better and
  leaves the cause.

</details>
