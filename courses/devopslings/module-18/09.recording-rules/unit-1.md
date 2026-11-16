---
title: "the latency panel times out on the week view"
---

## The situation

shop's dashboard has a "p99 latency by route" panel. Its query is in
`/obs/queries/latency-panel.promql`:

```
histogram_quantile(0.99, sum by (le, route) (rate(shop_http_request_duration_seconds_bucket[5m])))
```

Over the last hour it loads in a second. Over the last week it times out,
and the week view is the one used to decide whether last Tuesday's release
made shop slower.

## Why it is slow

A graph is a **range query**: the expression is evaluated once per step,
for every step across the time range. At each step this one reads 5 minutes
of raw samples for each of shop's bucket series (4 routes × 9 buckets), takes
the rate, sums and interpolates. Over a week at a 1-minute step, that is
about 10,000 evaluations, each reading thousands of samples, and the same
work is done again for everyone who opens the dashboard.

You can see the cost. `stats=all` makes Prometheus report how many samples a
query read:

```
curl -s prometheus:9090/api/v1/query_range --data-urlencode "query=$(cat /obs/queries/latency-panel.promql)" \
  --data-urlencode start=$(( $(date +%s) - 900 )) --data-urlencode end=$(date +%s) \
  --data-urlencode step=15 --data-urlencode stats=all | jq .data.stats.samples
```

## Recording rules

A **recording rule** makes Prometheus evaluate an expression on a schedule
(every 5 seconds here) and store the result as a new series. The panel then
reads one stored sample per route per step instead of recomputing it.

```yaml
groups:
  - name: example
    rules:
      - record: level:metric:operations
        expr: <the expression>
```

The name format `level:metric:operations` is a convention: the labels the
result keeps, the metric it comes from, and what was done to it. For example,
`job:http_requests:rate5m`.

## Your objectives

1. Write a recording rule in a new file under `/obs/prometheus/rules/`, then
   `obs-reload`.
2. Change `/obs/queries/latency-panel.promql` so it reads the recorded
   series.
3. The panel must show the same thing as before: the p99 over 5 minutes, one
   line per route.

`promtool check rules /obs/prometheus/rules/FILE.yml` checks a rule file
before you load it.

## What you're being graded on

- the panel's query, run as Grafana would over 15 minutes, reads fewer than
  5,000 samples and under an eighth of what the raw query reads (which is tens
  of thousands, and grows with the range)
- it returns one series per route, the same routes as the raw query
- for each route, its value matches the raw query's within 10%

<details>
<summary>Hint 1</summary>

The simplest rule records the panel's whole expression:

```yaml
- record: route:shop_http_request_duration_seconds:p99_rate5m
  expr: histogram_quantile(0.99, sum by (le, route) (rate(shop_http_request_duration_seconds_bucket[5m])))
```

and the panel's query becomes just the recorded name.

</details>

<details>
<summary>Hint 2 — when the panel and the raw query disagree</summary>

The rule has to compute exactly what the panel computed: the same quantile,
the same `[5m]` window, and the same `by (le, route)`. A rule over `[1m]`
loads fast and answers a different question.

</details>

<details>
<summary>Solution</summary>

`/obs/prometheus/rules/shop-latency.yml`:

```yaml
groups:
  - name: shop-latency
    rules:
      - record: route:shop_http_request_duration_seconds:p99_rate5m
        expr: histogram_quantile(0.99, sum by (le, route) (rate(shop_http_request_duration_seconds_bucket[5m])))
```

and the panel's query:

```
route:shop_http_request_duration_seconds:p99_rate5m
```

Recording one level lower is also common and more flexible:

```yaml
- record: route_le:shop_http_request_duration_seconds_bucket:rate5m
  expr: sum by (le, route) (rate(shop_http_request_duration_seconds_bucket[5m]))
```

with `histogram_quantile(0.99, route_le:shop_http_request_duration_seconds_bucket:rate5m)`
in the panel. It still reads only stored series, and any quantile, p50 or
p99.9, can be computed from the same rule.

A recorded series starts when the rule is loaded. Recording rules do not
backfill, so the week view fills in over the following week.
`promtool tsdb create-blocks-from rules` can backfill history if it is needed
sooner.

### The ways this goes wrong

- **A different window in the rule** (`[1m]` instead of `[5m]`). The panel
  is fast and shows a noisier number than it used to, under the same title.
- **Dropping `route`** from the `by (...)`. One line instead of four.
- **Dropping `le` before `histogram_quantile`.** The quantile needs the
  buckets; without `le` it has nothing to interpolate.
- **A `[5m:1m]` subquery in the panel instead of a rule.** It still reads
  the raw samples on every load, just at fewer points.

</details>
