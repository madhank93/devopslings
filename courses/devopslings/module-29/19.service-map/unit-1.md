---
title: "Something behind checkout is slow, and every graph blames shop"
---

## The situation

Four services take an order:

```
customers ──> shop ──> checkout ──> ledger
                           └──────> billing ──> ledger
```

Orders take about a third of a second, and the team wants to know where.
The graph they have is latency per service, from each service's root span:
shop at the top, checkout just under it. Someone has proposed giving shop
more CPU.

Every service sends its spans to the Collector (`/obs/otel/collector.yaml`),
which sends them on to Tempo. Each request a service serves is a `SERVER`
span; each call it makes is a `CLIENT` span, with the trace context passed
along. Prometheus's config is `/obs/prometheus/prometheus.yml`; run
`obs-reload` after editing it.

## Why per-service latency points the wrong way

A service's latency is the time from its request arriving to its reply
leaving. It includes every call that service makes and waits on. shop's
latency contains checkout's, and checkout's contains billing's and
ledger's. The slowest service on that graph is nearly always the one at the
top of the call chain, whatever is actually slow.

What you want is per **call**: for each pair of services, how long the
server took to answer the client. Then follow the slow calls down until
you find one whose server is slow while the calls *it* makes are fast. The
time in that service is its own.

## The service graph

The Collector's **servicegraph connector** builds that from spans. It
matches each `CLIENT` span with the `SERVER` span its call produced, and for
every edge (client service, server service) it emits:

- `traces_service_graph_request_total{client, server}`: calls on the edge
- `traces_service_graph_request_failed_total{client, server}`: failed calls
- `traces_service_graph_request_server_seconds` and
  `..._client_seconds`: histograms of the call's duration, as the server
  and as the client measured it

Like any connector, it is an exporter of a traces pipeline and a receiver
of a metrics pipeline, and that metrics pipeline needs an exporter
Prometheus can scrape. Grafana's Tempo datasource draws the same metrics as
a node graph, once they are in Prometheus.

## Your objectives

1. Get the service graph into Prometheus: an edge for every call in the
   system.
2. In `/obs/answers/bottleneck.txt`, name the slow call as
   `client -> server`, and give one PromQL query over the service graph's
   metrics that shows it.

## What you're being graded on

- Prometheus has a service-graph request counter for all four edges
- `edge` is the call where the time is spent, not the one that waits for it
- `metric` runs, uses the service graph's latency histogram, and returns a
  series for that edge

<details>
<summary>Hint 1 — read every edge at once</summary>

`histogram_quantile` over the server-latency histogram, summed by
`client, server, le`, gives one p95 per edge. Four rows.

</details>

<details>
<summary>Hint 2 — following it down</summary>

Two edges are slow and two are fast. One of the slow edges ends at a
service whose own outgoing calls are both fast. The other ends at a service
that waits on the first.

</details>

<details>
<summary>Solution</summary>

In `/obs/otel/collector.yaml`:

```yaml
connectors:
  servicegraph:
    metrics_flush_interval: 5s     # the default is 60s

exporters:
  # ...the two already there, plus:
  prometheus:
    endpoint: 0.0.0.0:8889

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [otlphttp/tempo, servicegraph]
    metrics/servicegraph:
      receivers: [servicegraph]
      exporters: [prometheus]
```

Scrape `collector:8889` from Prometheus and `obs-reload`. Then:

```
promq 'histogram_quantile(0.95, sum by (client, server, le) (rate(traces_service_graph_request_server_seconds_bucket[1m])))'
```

`shop -> checkout` and `checkout -> billing` are both about 300ms.
`billing -> ledger` and `checkout -> ledger` are tens of milliseconds at most. So
checkout's time is billing's, and billing's is its own:

```
edge: checkout -> billing
metric: histogram_quantile(0.95, sum by (client, server, le) (rate(traces_service_graph_request_server_seconds_bucket[1m])))
```

The next step is inside billing: a profile, or child spans around its
card-charging code. The service graph tells you which service to open, not
which line.

### The ways this goes wrong

- **shop, or shop -> checkout.** The top of the chain is always the
  slowest, because it waits for everything below it.
- **ledger.** It has the most calls, twice per order, so it tops any
  request-rate graph. Busy and slow are different questions.
- **A count as the evidence.** `request_total` shows where traffic goes.
  The proof is a latency, per edge.
- **Summing away the labels.** A query that adds every edge into one
  number cannot say which call it is about.

</details>
