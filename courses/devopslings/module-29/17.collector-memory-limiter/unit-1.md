---
title: "The Collector dies every night at the import"
---

## The situation

Every night the importer replays a day of orders as spans: thousands of
them, each with the order row attached, as fast as the Collector takes
them. The Collector sends them on to Tempo, and Tempo accepts only so many
bytes a second per tenant. Above that it answers `429`, and the
Collector's exporter keeps the rest in its sending queue and retries.

The Collector's container is allowed 256MiB. The queue has no idea, and
grows until the kernel kills the process. Everything in the queue goes
with it, and the importer was told `200` for every one of those spans.

The last fix was a bigger container. The next import was bigger too.

Run the burst yourself:

```
/obs/tools/importer
tail /obs/logs/collector.log    # "[supervise] collector exited with status 137"
```

Status 137 is 128 + 9: SIGKILL, which is what the kernel's OOM killer
sends. The Collector config is `/obs/otel/collector.yaml`; saving it
restarts the Collector.

## Refusing is better than dying

A process with a memory limit has two choices when more arrives than it can
hold: refuse some of it, or be killed holding all of it. The Collector
refuses only if it is told to, with the **`memory_limiter`** processor:

```yaml
processors:
  memory_limiter:
    check_interval: 100ms
    limit_percentage: 70          # hard limit, of the container's memory limit
    spike_limit_percentage: 25    # soft limit = hard limit - spike
```

Every `check_interval` it reads the Go heap. Above the **soft limit** it
refuses new data: the receiver answers `503` over HTTP or `UNAVAILABLE`
over gRPC, and a well-behaved sender (every OpenTelemetry SDK, and another
Collector) backs off and retries. Above the **hard limit** it also forces
a garbage collection. When memory falls back under the soft limit it
accepts again.

That is backpressure: the sender holds its data, and knows it has not
been delivered, until the Collector has room.

Three things decide whether it works:

- **It goes first.** Only the first processor can refuse to the sender.
  Anything ahead of it has already accepted the data, answered `200`, and
  spent the memory.
- **The limits are below the container's.** `limit_percentage` reads the
  container's cgroup limit; `limit_mib` is absolute and knows nothing of the
  container.
- **The spike covers one check interval.** Between two checks, data keeps
  arriving. `spike_limit` is the room left for it.

`batch` goes last, right before the exporter, so it batches only what
survived everything else.

## Your objectives

Make the Collector survive the importer's burst by pushing back on it, and
keep sending spans to Tempo afterwards.

## What you're being graded on

- in every traces pipeline, `memory_limiter` is the first processor and
  `batch` the last, and spans still go to Tempo
- the check restarts the Collector and runs a burst of its own: the
  Collector stays up, and refuses some of it
- after the burst, a new span is accepted and reaches Tempo

<details>
<summary>Hint 1 — what is actually growing</summary>

Watch the queue while the importer runs:

```
curl -s collector:8888/metrics | grep -E 'queue_size|enqueue_failed|refused'
```

The receiver keeps accepting, the exporter cannot send it as fast, and
the difference sits in memory.

</details>

<details>
<summary>Hint 2 — a smaller queue</summary>

`sending_queue.queue_size` caps the queue, and the Collector stays up. Look
at what it does with the overflow: `otelcol_exporter_enqueue_failed_spans`.
The importer was told `200` for those spans.

</details>

<details>
<summary>Solution</summary>

```yaml
processors:
  memory_limiter:
    check_interval: 100ms
    limit_percentage: 70
    spike_limit_percentage: 25
  batch:
    timeout: 1s

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlphttp/tempo]
    logs:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlphttp/loki]
```

Run `/obs/tools/importer` again: some requests come back `503`, and the
Collector's log shows no exit.

### The ways this goes wrong

- **More memory.** The queue grows until whatever the limit is. A bigger
  container moves the night it dies, not whether it does.
- **`memory_limiter` after `batch`.** `batch` has already accepted the data
  and answered `200`. The limiter can only drop what reaches it, and the
  sender never hears.
- **`limit_mib: 512`** on a 256MiB container. The limiter is waiting for a
  number the kernel never lets the process reach. `limit_percentage`
  follows the container.
- **A smaller sending queue, and nothing else.** The Collector stays up and
  drops the overflow, after telling the sender it was delivered.
- **A soft limit below what the Collector needs at rest.** It refuses for
  ever, and nothing gets through even after the burst.

</details>
