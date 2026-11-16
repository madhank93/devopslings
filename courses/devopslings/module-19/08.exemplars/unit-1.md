---
title: "checkout's p99 is over a second, and no trace anyone has opened is slow"
---

## The situation

checkout records how long each order takes in a histogram,
`checkout_duration_seconds`, and sends a trace of every order to Tempo. The
p99 is over a second:

```
promq 'histogram_quantile(0.99, sum by (le) (rate(checkout_duration_seconds_bucket[2m])))'
```

The team has opened a dozen traces in Grafana and every one of them took
about 100ms. One order in a hundred is slow, so picking traces at random
finds one about once in a hundred tries. The metric knows which requests
were slow, and the traces know why, but nothing joins the two.

checkout's source is `/obs/apps/checkout.py`. Saving it restarts checkout.
Prometheus scrapes it as the job `checkout`, and its config is
`/obs/prometheus/prometheus.yml`.

## Exemplars

An **exemplar** is one sample that a metric keeps alongside a bucket: a
value, a timestamp and a few labels, usually the ID of the trace that
produced it. With exemplars, the `le="2"` bucket of the histogram says "an
order took 1.07s, and here is its trace".

With the Python client, you attach one when you observe:

```python
DURATION.observe(seconds, exemplar={"trace_id": "4bf92f3577b34da6a3ce929d0e0e4736"})
```

The client keeps the latest exemplar for each bucket. Three things have to
line up before you can click from a panel to a trace:

1. **The ID has to be the request's own.** The current span is only current
   inside its `with` block. After the block, `trace.get_current_span()`
   returns an invalid span whose trace ID is 0. A span you create just to get
   an ID belongs to a trace of its own.
2. **The ID has to be in the form Tempo uses**: 32 lowercase hex digits,
   which is `format(trace_id, "032x")`. The SDK holds the trace ID as an
   integer.
3. **Prometheus has to receive the exemplars.** They exist only in the
   OpenMetrics text format. The classic Prometheus text format has no syntax
   for them, so a target scraped with that format loses them. The client
   library serves both formats and lets Prometheus choose with an `Accept`
   header. A job's `scrape_protocols` tells Prometheus which formats to ask
   for:

   ```
   curl -s -H 'Accept: application/openmetrics-text; version=1.0.0' checkout:9101/metrics | grep '#'
   ```

Grafana's Prometheus datasource is set up to open the exemplar label
`trace_id` in Tempo. In Explore, turn on **Exemplars** under the query. Each
exemplar is a dot on the graph that links to its trace. Prometheus serves
the same data at `/api/v1/query_exemplars`.

## Your objectives

1. Make every observation of `checkout_duration_seconds` carry the order's
   trace ID as the exemplar label `trace_id`.
2. Get those exemplars into Prometheus.
3. Open a slow one, and write in `/obs/answers/exemplars.txt` what makes the
   slow orders slow:

   ```
   cause: <which step, and why it takes as long as it does>
   ```

## What you're being graded on

- checkout's `/metrics` has exemplars on the histogram, labelled `trace_id`,
  with real 32-hex trace IDs
- Prometheus has stored them
- the exemplar for an order slower than a second leads to a trace in Tempo
  that is that order, with a `POST /checkout` span that took as long as the
  exemplar says
- the `cause:` line names the step that takes the time, and why

<details>
<summary>Hint 1 — which span</summary>

`take_order` opens `POST /checkout` as `span`. The observation is made after
that block ends. Keep the trace ID from inside the block.

</details>

<details>
<summary>Hint 2 — exemplars on /metrics, none in Prometheus</summary>

Compare what checkout serves when asked for OpenMetrics with what Prometheus
asks it for. Look at the `checkout` job in `prometheus.yml`, and remember
`obs-reload`.

</details>

<details>
<summary>Solution</summary>

In `/obs/apps/checkout.py`:

```python
        publish(order)
        trace_id = format(span.get_span_context().trace_id, "032x")
    DURATION.observe(time.perf_counter() - start, exemplar={"trace_id": trace_id})
```

In `/obs/prometheus/prometheus.yml`, delete the `scrape_protocols` line from
the `checkout` job, so Prometheus asks for OpenMetrics first, then run
`obs-reload`.

A slow exemplar's trace looks like this:

```
POST /checkout   1.07s
  price          0.05s
  coupon.lookup  1.02s
    coupon.attempt  1.00s  attempt=1  error: timed out after 1s
    coupon.attempt  0.02s  attempt=2
  publish orders 0.01s
```

```
cause: about 3% of orders apply a coupon whose first lookup times out after 1s and is retried
```

One order in ten has a coupon, and the coupon service fails to answer three
times in ten. Each of those waits out a full one-second timeout before the
retry succeeds in 20ms. That makes 3% of orders, which is enough to own the
p99 and too few to find by browsing.

### The ways this goes wrong

- **Exemplars on /metrics and none in Prometheus.** The job still asks for
  `PrometheusText0.0.4`, which has no syntax for exemplars, and checkout
  answers in the format it is asked for. Nothing reports an error.
- **`trace.get_current_span()` at the observation.** The observation is
  outside the `with` block, so there is no current span and every exemplar
  says `00000000000000000000000000000000`.
- **`str(trace_id)`.** A 39-digit decimal number. Tempo does not recognise it.
- **A new span for the observation.** Its trace ID is real, and its trace
  holds one empty span. The exemplar has to point at the request it measured.
- **A label other than `trace_id`.** Prometheus stores it, and Grafana does
  not turn it into a link, because the datasource maps `trace_id`.
- **"price is slow" or "the queue is slow".** Those are what the average
  order spends its time on. The slow orders spend theirs waiting out a
  timeout.

</details>
