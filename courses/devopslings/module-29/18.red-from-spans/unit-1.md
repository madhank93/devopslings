---
title: "checkout has traces and no metrics"
---

## The situation

checkout is the shop's cart and checkout API on `checkout:8080`:

```
GET  /cart          the customer's cart
POST /checkout      places an order; a declined card is a 500
GET  /orders/<id>   one order
```

Every request becomes a span, sent over OTLP to the Collector, which sends
it on to Tempo. Storing every trace cost too much, so the Collector keeps one
in ten (`probabilistic_sampler` in `/obs/otel/collector.yaml`).

There are no metrics. Nobody can say how many requests checkout serves, how
many fail, or how slow `/checkout` is at p99, and the team that owns it does
not want a metrics library in the code. The spans already carry everything
those three numbers need: one span per request, its name, its duration and
its status.

The Collector restarts when you save its config, and its log is
`/obs/logs/collector.log`. Prometheus's config is
`/obs/prometheus/prometheus.yml`; run `obs-reload` after editing it.

## RED, from spans

**RED** is three numbers per endpoint: **R**ate of requests, **E**rrors,
and **D**uration. A span per request is enough to compute all three.

The Collector's **spanmetrics connector** does it. A **connector** is the
end of one pipeline and the start of another: listed as an exporter of a
traces pipeline, it consumes spans; listed as a receiver of a metrics
pipeline, it emits what it computed from them. For every combination of
service, span name, span kind and status code it keeps:

- a counter of calls (`traces_span_metrics_calls_total` once Prometheus
  has it): rate, and errors where `status_code="STATUS_CODE_ERROR"`
- a histogram of durations (`traces_span_metrics_duration_milliseconds`):
  duration

```yaml
connectors:
  spanmetrics:
    metrics_flush_interval: 5s     # how often it emits; the default is 60s
```

The metrics pipeline still needs an exporter Prometheus can reach. The
`prometheus` exporter serves them on an endpoint you choose, for a scrape
job to pick up.

## Your objectives

Get rate, errors and duration for each of checkout's routes into Prometheus,
from the spans, counting every request. Tempo keeps storing one trace in ten.

## What you're being graded on

The check restarts the Collector, so its counters start at zero, then sends
checkout 400 `GET /cart`, 300 `POST /checkout` (60 of them declined) and
200 `GET /orders/<id>`. Then, in Prometheus:

- a spanmetrics calls counter per route matches what was sent within 2%,
  and counts the 60 declined checkouts as errors
- a duration histogram per route counts the same requests
- Tempo stored no more than a quarter of the 400 cart traces

<details>
<summary>Hint 1 — where the connector sits</summary>

Processors run in order, and an exporter sees what is left after all of
them. Put the connector in the existing traces pipeline and count what it
reports for 400 requests.

</details>

<details>
<summary>Hint 2 — two pipelines, one receiver</summary>

One receiver can feed several pipelines. A traces pipeline with no sampler
can end in the connector, while the pipeline with the sampler goes on to
Tempo.

</details>

<details>
<summary>Solution</summary>

In `/obs/otel/collector.yaml`, add the connector, an exporter and two
pipelines. The existing traces pipeline stays as it was:

```yaml
connectors:
  spanmetrics:
    metrics_flush_interval: 5s

exporters:
  # ...the two already there, plus:
  prometheus:
    endpoint: 0.0.0.0:8889

service:
  pipelines:
    # ...logs and traces as before, plus:
    traces/red:
      receivers: [otlp]
      processors: [batch]
      exporters: [spanmetrics]
    metrics/red:
      receivers: [spanmetrics]
      exporters: [prometheus]
```

Scrape it, in `/obs/prometheus/prometheus.yml`, then `obs-reload`:

```yaml
  - job_name: spanmetrics
    static_configs:
      - targets: ["collector:8889"]
```

Rate, errors and p99 per route:

```
promq 'sum by (span_name) (rate(traces_span_metrics_calls_total{service_name="checkout"}[1m]))'
promq 'sum by (span_name) (rate(traces_span_metrics_calls_total{service_name="checkout",status_code="STATUS_CODE_ERROR"}[1m]))'
promq 'histogram_quantile(0.99, sum by (span_name, le) (rate(traces_span_metrics_duration_milliseconds_bucket{service_name="checkout"}[1m])))'
```

### The ways this goes wrong

- **The connector after the sampler.** Added to the existing traces
  pipeline, it counts the one span in ten that survives
  `probabilistic_sampler`: a rate a tenth of the truth, and an error rate
  that is noise. Metrics derived from spans have to be computed before
  anything drops spans.
- **Turning the sampler off.** The counts come out right and Tempo stores
  ten times as much. The point of deriving metrics in the Collector is that
  counting is cheap and storing is not.
- **Scraping `:8888`.** That is the Collector's own telemetry: spans
  received, spans exported, queue sizes. It says nothing about checkout.
- **The connector in only one pipeline.** A connector has to be an exporter
  somewhere and a receiver somewhere else, and the Collector refuses to
  start otherwise. Read the reason in `/obs/logs/collector.log`.
- **Waiting a minute for nothing.** With the default
  `metrics_flush_interval` of 60s, new counts show up a minute late. Short
  intervals are fine here; in production 15s to 60s keeps the export cost
  down.

</details>
