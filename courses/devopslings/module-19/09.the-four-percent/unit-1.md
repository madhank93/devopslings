---
title: "Finance counts 4% fewer invoices in the logs than billing issued"
---

## The situation

billing logs one line for every invoice it issues, and sends its logs to the
Collector over OTLP. The Collector ships them to Loki. Every morning finance
counts invoice lines in Loki and compares the count with the ledger. Loki
comes up a few percent short, every day.

The Collector's log has no errors in it. billing's log has no errors in it.
The ticket's first theory is that billing sometimes forgets to log.

billing counts every line it hands to the Collector, so you can test that
theory:

```
promq 'increase(billing_log_records_total[5m])'
logcli query 'sum(count_over_time({service_name="billing"}[5m]))'
```

The Collector config is `/obs/otel/collector.yaml`. The Collector reports on
itself at `collector:8888/metrics`, and Prometheus now scrapes it as job
`collector`.

## How a Collector loses data quietly

Every component counts what passes through it:

| metric | meaning |
|---|---|
| `otelcol_receiver_accepted_log_records_total` | taken in from senders |
| `otelcol_receiver_refused_log_records_total` | refused; the sender was told |
| `otelcol_processor_batch_batch_send_size_sum` | handed on by the batch processor |
| `otelcol_exporter_sent_log_records_total` | delivered to the backend |
| `otelcol_exporter_enqueue_failed_log_records_total` | dropped: the sending queue was full |
| `otelcol_exporter_send_failed_log_records_total` | dropped: the backend refused, and retries ran out |

Follow the records down that list. Wherever the count falls, that component
lost them.

An exporter's **sending queue** sits between the pipeline and the network.
`queue_size` is how much it holds, counted in requests (batches) unless
`sizer: items` makes it count records. `num_consumers` is how many sends run
at once. When something arrives and the queue is full, the exporter drops it
and counts it. If a batch processor sits upstream, the drop happens after the
sender was told "accepted". Nobody downstream is told either.

## Your objectives

1. Find where the lines go missing. Write the component in
   `/obs/answers/the-four-percent.txt`:

   ```
   where: <the component that drops them>
   ```

2. Fix the Collector so that bursts arrive whole. Month-end settlement runs
   send 1000 lines in one request, and invoices arrive 50 at a time.
3. Add an alert named `LogRecordsDropped` in a rule file under
   `/obs/prometheus/rules/`. It must fire while the Collector's exporters
   are dropping log records, either way they can drop them, and stay quiet
   otherwise. Run `obs-reload` after saving it.

## What you're being graded on

- a settlement run of 1000 lines in one request reaches Loki whole
- 50 requests of 20 lines, sent at the same moment, reach Loki whole
- `LogRecordsDropped`, tested with `promtool` against made-up histories:
  - fires while `enqueue_failed` climbs
  - fires while `send_failed` climbs and `enqueue_failed` does not exist yet
  - stays quiet when both counters are non-zero and flat
- the answer names the component that dropped the lines

<details>
<summary>Hint 1 — where</summary>

`curl -s collector:8888/metrics | grep log_records` and compare the numbers
down the pipeline. Then match a jump in the dropped count with one of
billing's settlement runs, every 30 seconds.

</details>

<details>
<summary>Hint 2 — why the steady trickle is fine</summary>

The batch processor cuts batches of 20. A settlement run arrives as one
request of 125 lines and becomes 7 batches in a few microseconds. The queue
holds 5, and one consumer sends them one at a time.

</details>

<details>
<summary>Hint 3 — the alert</summary>

The Collector only exports a counter once it has something to count. Ask
whether each counter is going up, and combine the two answers with `or`.
`+` returns nothing when either side has no series.

</details>

<details>
<summary>Solution</summary>

The lines are dropped by the `otlphttp/loki` exporter's sending queue, and
`otelcol_exporter_enqueue_failed_log_records_total` jumps every 30 seconds.
billing logged every one of them. The receiver accepted them, and the batch
processor handed every one on.

```yaml
exporters:
  otlphttp/loki:
    endpoint: http://loki:3100/otlp
    sending_queue:
      num_consumers: 4
      sizer: items
      queue_size: 20000
    retry_on_failure:
      enabled: true
      max_elapsed_time: 10m
```

Counting the queue in records rather than batches makes its size mean the
same thing whatever the batching does. 20000 records hold a month-end run
many times over, and the memory cost is small. Four consumers drain it four
times as fast. Retries let it hold data through a short Loki outage instead
of dropping it at the first refusal.

```yaml
groups:
  - name: log-pipeline
    rules:
      - alert: LogRecordsDropped
        expr: |
          sum by (exporter) (increase(otelcol_exporter_enqueue_failed_log_records_total[5m])) > 0
          or
          sum by (exporter) (increase(otelcol_exporter_send_failed_log_records_total[5m])) > 0
        labels:
          severity: page
```

### The ways this goes wrong

- **Blaming billing.** Its own counter and the Collector's receiver agree to
  the line. Restarting billing, or adding logging to it, changes nothing.
- **`queue_size: 10`.** That covers today's 125-line run. The month-end run is
  1000 lines, and it is dropped the same way.
- **Turning retries on.** Retries help when the backend refuses. Here the
  backend never saw the records: they were dropped before they were queued.
- **Removing the batch processor.** The settlement run becomes one queue
  entry and gets through. Fifty invoices arriving at once are fifty entries,
  and the receiver answers 503. billing does not read the answer.
- **`otelcol_exporter_enqueue_failed_log_records_total > 0`.** Once there has
  been one drop, this fires until the Collector restarts.
- **Watching only `enqueue_failed`.** A Loki outage longer than the retry
  window shows up only in `send_failed`.

</details>
