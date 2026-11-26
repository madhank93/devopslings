---
title: "Leaving the vendor without going dark"
---

## The situation

`/obs/migration/INVENTORY.md` has the facts. In short: forty services send
OTLP to the Collector, and the Collector sends everything to Acme, the APM
vendor. 120 dashboards and 65 alerts live in Acme's UI, twelve of those
alerts page the on-call, and the contract ends in ninety days. Grafana,
Prometheus and Tempo are already running and empty.

The Collector's config is `/obs/otel/collector.yaml`; it restarts on save.
What Acme has received:

```
curl -s billing:4318/stats | jq
```

(For this lab, Acme's intake runs in the `billing` container.)

## Why big-bang fails

The tempting plan is a date: on that day, point the Collector at Tempo and
turn Acme off. Everything that goes wrong with it goes wrong the same day,
with no way to tell:

- the new stack has never seen a Monday peak or the Saturday batch
- the alerts that page the on-call are in a system that no longer gets data
- the first time anyone opens the new dashboards is during an incident
- if something is missing, the only fallback was just switched off

A migration without a gap runs both for a while:

1. **Dual-ship**: one pipeline, two exporters. Acme keeps everything it has
   today; the new stack fills up next to it. The Collector makes this a
   config change, and it is the point of putting a Collector in front of a
   vendor in the first place.
2. **Parity**: measure, before trusting it, that the new stack sees what
   Acme sees: a number both can produce, a threshold, and long enough to
   include the traffic's whole cycle.
3. **Move what people use**: dashboards rebuilt and compared, alerts run in
   parallel and compared, then the pager moves.
4. **Cut over**, keep Acme receiving as the rollback, then **decommission**.

## Your objectives

1. Start the dual-ship: the Collector sends every span to Acme *and* to
   Tempo (`http://tempo:4318`).
2. Write the plan in `/obs/answers/migration.txt`.

## What you're being graded on

- spans the check sends through the Collector arrive at both Acme and Tempo
- `phases` puts dual-ship, parity, and moving alerts and dashboards before
  cut-over, and decommission after it
- parity has a metric, a numeric threshold, and a window of at least a week
- `alerts` and `dashboards` say how each moves without a gap
- `rollback` says what it rolls back to

<details>
<summary>Hint 1 — the dual-ship</summary>

A pipeline's `exporters` is a list. Every exporter in it gets every batch.

</details>

<details>
<summary>Hint 2 — the window</summary>

What does INVENTORY.md say runs only once a week?

</details>

<details>
<summary>Solution</summary>

In `/obs/otel/collector.yaml`:

```yaml
exporters:
  otlphttp/acme:
    endpoint: http://billing:4318
  otlphttp/tempo:
    endpoint: http://tempo:4318

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [otlphttp/acme, otlphttp/tempo]
```

And the plan:

```
phases: instrument, dual-ship, parity, move-dashboards, move-alerts, cut-over, decommission
parity_metric: spans per service per hour, and error rate and p99 per route, from both backends side by side
parity_threshold: 1% in span count, 5% in p99
parity_window: 14 days
alerts: rebuilt as Prometheus rules and run in parallel with Acme's for two weeks to a test channel; the pager moves service by service once each fired when Acme's did
dashboards: rebuilt in Grafana and compared side by side with Acme's for the same hours, then Acme's are made read-only
rollback: Acme keeps receiving until decommission, 30 days after cut-over; if the new stack misses an incident, the pager goes back to Acme's alerts that day
```

Two weeks covers two Monday peaks and two Saturday batches. The
dual-ship costs double for those weeks; that is the price of not going
dark, and it is smaller than one incident nobody could see.

### The ways this goes wrong

- **Pointing the Collector at Tempo.** The big-bang cut-over, done on day
  one: Acme's alerts stop firing and nobody notices until something breaks.
- **Parity "looks fine".** Without a number and a threshold, cut-over day
  is whenever someone gets bored of waiting.
- **Parity over a weekday.** The Saturday batch never ran, and its traces
  go missing in production.
- **Alerts last.** Dashboards are for looking; alerts are what wakes people
  up. A window where alerts point at the old system after cut-over is a
  window where nothing pages.
- **Turning Acme off at cut-over.** Then there is nothing to roll back to.

</details>
