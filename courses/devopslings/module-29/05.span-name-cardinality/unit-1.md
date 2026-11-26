---
title: "Every new order adds a spanmetrics series"
---

## The situation

checkout serves `GET /orders/<id>` and traces every request. The Collector's
**spanmetrics connector** turns those spans into request counts and latency
histograms, so nobody has to instrument metrics separately, and Prometheus
scrapes them as job `spanmetrics`.

The metrics team flagged checkout: its series count climbs all day and never
comes down.

```
promq 'count(traces_span_metrics_calls_total{service_name="checkout"})'
promq 'traces_span_metrics_calls_total{service_name="checkout"}' | head
```

The team's first guess is the `order.id` attribute: an id per order sounds
like the cardinality problem from module 18. They want to drop it.

The source is `/obs/apps/checkout.py`. Saving it restarts checkout; its
output is in `/obs/logs/checkout.log`. The Collector's config is
`/obs/otel/collector.yaml`.

## What spanmetrics counts by

The connector keeps one series for each combination of its **dimensions**.
By default they are:

| Dimension | Label |
|---|---|
| the resource's `service.name` | `service_name` |
| the span's name | `span_name` |
| the span's kind | `span_kind` |
| the span's status | `status_code` |

Span attributes are not dimensions unless you list them under `dimensions:`
in the connector's config. `order.id` never reached a series. The span
**name** did: checkout names each span `GET /orders/8812`, so each order is a
new `span_name`, a new series, and a new set of histogram buckets.

A span name says what kind of operation this was, and stays the same across
requests of the same kind. The specifics of one request (the order, the user,
the query string) are attributes. For an HTTP server span the convention is
`{method} {route}`, with the route as a template: `GET /orders/{id}`.

The attribute is what you search by when one customer complains about one
order:

```
{resource.service.name="checkout" && span.order.id="8812"}
```

Drop it and the metrics stay broken, and that search stops working too.

## Your objectives

Stop checkout's spans from adding a spanmetrics series per order, and keep
each order's id on its span as `order.id`. Keep the connector's default
dimensions.

## What you're being graded on

The check fetches 50 orders with ids nobody has used before, each with a
`traceparent` of its own, then:

- reads each request's span from Tempo, and finds the order's id on it as
  `order.id`
- reads the span names checkout sent: one name, for the route, with no id in
  it
- counts the new `traces_span_metrics_calls_total` series for checkout on
  `collector:8889`: at most 5 across the 50 orders

<details>
<summary>Hint 1 — where the id is</summary>

Look at the `span_name` label of the series, and at the line in
`checkout.py` that starts the span.

</details>

<details>
<summary>Hint 2 — the series that already exist</summary>

The series made before your fix stay until the Collector restarts. The check
counts only the series its own 50 requests add.

</details>

<details>
<summary>Solution</summary>

In `/obs/apps/checkout.py`, name the span after the route, and keep the
attribute:

```python
with tracer.start_as_current_span("GET /orders/{id}", context=ctx,
                                  kind=trace.SpanKind.SERVER) as span:
    span.set_attribute("order.id", order_id)
```

That is a plain string, not an f-string: the `{id}` is part of the name.

From now on checkout has one series per status for that route, however many
orders there are.

### The ways this goes wrong

- **Dropping `order.id`.** The series keep climbing, because the id is still
  in the name, and the search by order stops working. The check says so.
- **Adding `order.id` to the connector's `dimensions`.** The name is fixed,
  and each order is a new series again, through a label this time.
- **`metrics_expiration` or a cardinality limit on the connector.** Old
  series go away or fold into an overflow series, and the span names still
  carry the id into Tempo, Grafana and anything else that reads them.
- **Naming every span `GET`.** Bounded, and it no longer says which
  endpoint was slow once checkout has a second route.

</details>
