---
title: "Prometheus's memory tripled after shop's deploy"
---

## The situation

shop shipped a small change this morning. Since then Prometheus's memory has
kept climbing:

```
promq 'prometheus_tsdb_head_series'
promq 'process_resident_memory_bytes{job="prometheus"}'
```

The obvious fix is a bigger memory limit. That buys an hour, and the climb
continues, because the cause is still deploying new series every second.

## Cardinality

A Prometheus **series** is one metric name plus one exact set of label
values. Prometheus keeps every series it has seen recently in memory (the
*head block*, about two hours), and memory grows with the number of series,
not with the number of samples.

So a metric's cost is the product of its labels' value counts.
`method × route × code` for shop's request counter is about 1 × 4 × 2. A
label whose value is different for every user, order or request multiplies
that by the number of users, orders or requests. A histogram multiplies it
again by its number of buckets.

To find where series come from:

```
promq 'topk(5, count by (__name__) ({job="shop"}))'          # which metrics
promq 'scrape_samples_post_metric_relabeling{job="shop"}'    # series per scrape
promq 'count by (route) (shop_http_requests_total)'          # values of one label
```

Prometheus's own page **Status → TSDB status** lists the metrics and labels
with the most series.

## Your objectives

1. Bring shop under **150 series per scrape**, and keep it there as new
   customers arrive.
2. Keep the question the deploy was trying to answer answerable: request
   rate, errors and p99 latency **per endpoint**, which dashboards and alerts
   ask with `route="/orders/:id"`.

shop's source is `/obs/apps/shop.py`; saving it restarts shop. Scrape config
is in `/obs/prometheus/prometheus.yml` (`obs-reload` after editing).

## What you're being graded on

- shop's series per scrape, `scrape_samples_post_metric_relabeling`, is
  under 150, and still under twenty seconds later
- shop is still scraped (`up == 1`)
- `shop_http_requests_total` and the latency histogram have
  `route="/orders/:id"` series, and the p99 for that route has an answer
- shop's request counts add up to what loadgen sent, and `/orders/:id` gets
  its share

The check waits for a minute of data after your fix goes live.

<details>
<summary>Hint 1 — the label</summary>

```
promq 'count(count by (path) (shop_http_requests_total))'
```

The deploy replaced the `route` label with `path`, the exact path a customer
requested. `/orders/12345` and `/orders/12346` are different values. Look at
`route_of()` in `shop.py`, and at what the deploy changed around it.

</details>

<details>
<summary>Hint 2 — where to fix it</summary>

Relabelling at scrape time looks tempting: `metric_relabel_configs` can drop
or rewrite `path`. Before you try it, ask what happens when shop exposes
`path="/orders/1"` and `path="/orders/2"` in one scrape and both are rewritten
to the same labels. Prometheus can store only one sample per series per
scrape.

The labels should be right where the series are made.

</details>

<details>
<summary>Solution</summary>

Label by the route template again, in `shop.py`:

```python
REQUESTS = Counter(
    "shop_http_requests_total", "HTTP requests served, by route template and status code.",
    ["method", "route", "code"])
LATENCY = Histogram(
    "shop_http_request_duration_seconds", "Time to serve an HTTP request.",
    ["route"], buckets=(...))
...
        if route is not None:
            REQUESTS.labels("GET", route, str(code)).inc()
            LATENCY.labels(route).observe(time.time() - start)
```

`route_of()` already turns `/orders/12345` into `/orders/:id`. The deploy
stopped using it.

`prometheus_tsdb_head_series` will not drop right away. Old series stay in
the head block until it is compacted, about two hours later, which is why a
memory graph keeps an incident visible after it is fixed. What changes
straight away is the growth.

The deploy's goal, finding the slow order, is a real question with a
different tool. A log line or a trace per request can carry the order ID,
because each request is stored once and not kept as a series in memory.
That is module 19.

### The wrong fixes

- **More memory for Prometheus.** The growth has no end; each new order ID
  adds about fourteen series (a counter plus a histogram's buckets).
- **`sample_limit`** in the scrape config. It is a safety net, not a fix:
  over the limit, Prometheus rejects the whole scrape, and shop disappears
  from every dashboard.
- **`labeldrop` on `path`**, or rewriting it with `metric_relabel_configs`.
  The rewritten series collide, Prometheus keeps one sample per series per
  scrape and rejects the rest
  (`prometheus_target_scrapes_sample_duplicate_timestamp_total`), and the
  counts become nonsense. Dropping `path` without putting `route` back also
  loses the per-endpoint question.
- **Dropping the histogram.** That is under budget too, and the p99 has no
  answer.

</details>
