---
title: "the counter that saws"
---

## The situation

The ticket service (`/obs/apps/lab.py`) is instrumented with the
OpenTelemetry SDK, not `prometheus_client`. It answers exactly 8 requests a
second, counts them in `tickets.requests`, and every 5 seconds exports the
count over OTLP to the Collector, which forwards it to `prometheus-2`'s OTLP
receiver. Ask prometheus-2 how busy the service is:

```
PROM=http://prometheus-2:9090 promq 'rate(tickets_requests_total[1m])'
PROM=http://prometheus-2:9090 promq 'tickets_requests_total[30s]'
```

The rate is close to zero, and the raw samples are not a counter at all:
they sit around 40, going up and down by one. Graph it in Grafana
(<http://localhost:13000>, add a Prometheus datasource at
`http://prometheus-2:9090` or use Explore) and it is a sawtooth.

## Delta and cumulative

An OpenTelemetry sum has a **temporality**:

- **cumulative**: each point is the total since the process started. This
  is what a Prometheus counter is: `3001`, `3041`, `3081`.
- **delta**: each point is the count since the previous export: `40`, `40`,
  `41`, `39`.

Some backends prefer deltas (they add them up themselves); Prometheus does
not. Every counter function in PromQL, `rate`, `increase`, `resets`,
assumes running totals, and reads a value that went down as the process
restarting. Over deltas, `rate()` measures the noise in the deltas.

The SDK here asks for deltas (`preferred_temporality` in lab.py), and
prometheus-2 was started with `--enable-feature=otlp-native-delta-ingestion`
(`/obs/prometheus-2/run.sh`), which stores delta samples as they come. That
flag exists for backends that will query them as deltas; it makes the
deltas visible, it does not make them a counter.

There are three places to turn deltas into totals:

- the SDK: export cumulative in the first place;
- the Collector: the `deltatocumulative` processor keeps a running total per
  series and emits that;
- Prometheus: `--enable-feature=otlp-deltatocumulative` does the same on
  ingest.

The Collector is the one that covers every service sending through it,
including ones you do not own. Whichever you pick, a process restart starts
the total from zero again, which is a reset `rate()` already understands.

## Your objectives

1. Make `tickets_requests_total` in prometheus-2 a running total.
2. Keep the service sending through the Collector.

Saving `/obs/apps/lab.py`, `/obs/otel/collector.yaml` or
`/obs/prometheus-2/run.sh` restarts that process; their output is in
`/obs/logs/lab.log`, `/obs/logs/collector.log` and
`/obs/logs/prometheus-2.log`.

## What you're being graded on

- `rate(tickets_requests_total[30s])` in prometheus-2 is within 1 of 8 a
  second, with no counter resets in the window, three times in a row

<details>
<summary>Hint 1</summary>

`switching to increase()` or a `[10m]` window changes the question, not the
data. Look at the samples, and at what kind of number each one is.

</details>

<details>
<summary>Hint 2</summary>

In `/obs/otel/collector.yaml`, declare a `deltatocumulative` processor (it
needs no settings) and put it in the metrics pipeline's `processors`, before
`batch`.

</details>

<details>
<summary>Solution</summary>

In `/obs/otel/collector.yaml`:

```yaml
processors:
  batch:
    timeout: 1s
  deltatocumulative: {}

service:
  pipelines:
    metrics:
      receivers: [otlp]
      processors: [deltatocumulative, batch]
      exporters: [otlphttp/prometheus]
```

Or in the SDK, in `/obs/apps/lab.py`:

```python
preferred_temporality={Counter: AggregationTemporality.CUMULATIVE},
```

(cumulative is the SDK's default, so deleting the argument does the same).

The first 30 seconds after the change mix old deltas with new totals; the
check waits that out.

### The ways this goes wrong

- **`increase()`, or a longer window.** Same samples, same misreading.
- **Removing `otlp-native-delta-ingestion`.** Prometheus then drops delta
  samples it has no instruction for, so the sawtooth disappears along with
  the metric.
- **`deltatocumulative` declared but not in the pipeline.** A processor that
  is not listed in a pipeline does nothing; the Collector does not even
  build it.
- **A `deltatocumulative` behind a load balancer of Collectors.** The
  running total lives in one Collector's memory, so every delta for a series
  has to reach the same Collector. One gateway, as here, is fine.

</details>
