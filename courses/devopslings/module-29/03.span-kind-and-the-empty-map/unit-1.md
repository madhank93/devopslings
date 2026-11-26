---
title: "Every service is traced, and the service graph is empty"
---

## The situation

`POST /checkout` on checkout asks fulfil to reserve the order's stock, and
fulfil books it with ledger. All three use the OpenTelemetry SDK and send
their spans to the Collector, and each request is one trace with all three
services in it. Open one in Grafana (Explore, Tempo) and the tree is right.

The platform team added the Collector's **servicegraph connector** so the
on-call would have a map of who calls whom, with request rates and latency
per edge. It has produced nothing:

```
promq 'traces_service_graph_request_total'
curl -s collector:8889/metrics | grep service_graph
```

The team's first guess is that the connector is misconfigured. Read
`/obs/otel/collector.yaml`: it is in the traces pipeline as an exporter and
feeds a metrics pipeline as a receiver, which is all it needs. Its question
is about the spans.

The sources are `/obs/apps/{checkout,fulfil,ledger}.py`. Saving one restarts
that service; output is in `/obs/logs/<name>.log`.

## Span kind

Every span has a **kind**, which says what role the operation plays:

| Kind | The span is |
|---|---|
| `SERVER` | handling a request that came from another process |
| `CLIENT` | making a request to another process and waiting for it |
| `PRODUCER` / `CONSUMER` | sending or receiving a message that is handled later |
| `INTERNAL` | work inside the process; the default |

The tree of parent and child IDs says which span caused which. The kind says
where the process boundaries are. A tool cannot tell a function call from a
network call by looking at the tree: both are a parent with a child.

The servicegraph connector builds an edge from a **pair**: a `CLIENT` span
in one service, and a `SERVER` span whose parent is that client span, in
another. It keeps unpaired spans for `store.ttl` and then drops them. When
every span is `INTERNAL`, nothing ever pairs, and the connector, correctly,
reports no edges. So do Tempo's own service graph and most APM tools.

Kind is set when a span starts:

```python
with tracer.start_as_current_span("POST /reserve", kind=trace.SpanKind.CLIENT):
```

Auto-instrumentation libraries set it for you. Hand-written spans default to
`INTERNAL`.

## Your objectives

Make the service graph show checkout → fulfil and fulfil → ledger, without
changing the Collector. Keep the span names and the trace tree as they are.

## What you're being graded on

The check sends 20 requests to `POST /checkout` and reads the connector's
metrics on `collector:8889`:

- `traces_service_graph_request_total{client="checkout", server="fulfil"}`
  rises by exactly 20
- `traces_service_graph_request_total{client="fulfil", server="ledger"}`
  rises by exactly 20

If an edge is missing, it says which span has the wrong kind.

<details>
<summary>Hint 1 — which spans</summary>

There are two kinds of span in each service here: the one that handles the
incoming request, and, in checkout and fulfil, the one around the outgoing
call. They need different kinds.

</details>

<details>
<summary>Hint 2 — one edge, two services</summary>

An edge needs a span at each end. Fixing checkout alone gives the connector
a CLIENT span with an INTERNAL child: still nothing.

</details>

<details>
<summary>Solution</summary>

In all three services, the handler's span is `SERVER`:

```python
with tracer.start_as_current_span("POST /checkout", context=ctx, kind=trace.SpanKind.SERVER):
```

In checkout and fulfil, the span around the call is `CLIENT`:

```python
with tracer.start_as_current_span("POST /reserve", kind=trace.SpanKind.CLIENT) as span:
```

Nothing in the Collector changed. Within ten seconds or so the two edges
appear, with a count per request.

### The ways this goes wrong

- **Tuning the connector.** A longer `store.ttl`, a shorter flush interval,
  `virtual_node_peer_attributes`: none of them pairs an INTERNAL span with
  anything.
- **Every span `SERVER`.** Each service now says it handles a request, and
  nobody says they made one. There is still no CLIENT end.
- **CLIENT on the calls, nothing on the handlers.** The connector holds each
  client span waiting for a server child that never arrives, and drops it.
- **Fixing one hop.** checkout → fulfil appears, and fulfil → ledger stays
  missing until fulfil's call and ledger's handler are fixed too.

</details>
