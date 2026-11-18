---
title: "The average of four p99s"
---

## The situation

Search runs as four replicas, `a` to `d`, behind one load balancer. The
objective is a fleet p99 under **800ms**, and the fleet dashboard computes it
like this:

```
avg(search_latency_seconds{quantile="0.99"})
```

Each replica reports its own p99, the panel averages the four, and it reads
about 490ms. Comfortably green.

But replica `d` holds the hot shard. Look at the replicas side by side, from
the box:

```
promq 'search_latency_seconds{quantile="0.99"}'
promq 'sum by (replica) (rate(search_latency_hist_seconds_count[1m]))'
```

Every replica exports its latency twice:

- `search_latency_seconds` is a **summary**: the replica sorts its own last
  minute of requests and reports the 50th, 90th and 99th percentiles as
  finished numbers.
- `search_latency_hist_seconds` is a **histogram**: it reports how many
  requests fell at or under each bucket boundary, and leaves the percentile to
  the query.

## Why the average of percentiles is not a percentile

A percentile is a rank in one sorted list. Four replicas have four lists,
and the fleet's p99 is a rank in all four merged. Averaging four p99s gives
each replica the same weight however much traffic it served, and ignores
where in each list the slow requests are. It is not an estimate of the fleet
p99 that is a bit off; it is a different number, and it can be wrong in
either direction by any amount.

A summary's percentiles cannot be merged at all: the replica threw away the
requests and kept only the answer. A histogram's buckets are counts, and
counts add. Sum the four replicas' buckets and you have the fleet's
histogram, from which `histogram_quantile` estimates the fleet's p99.

## Your objectives

1. Get the number the dashboard shows: the average of the four p99s.
2. Compute the fleet's p99 from the histogram buckets, with one PromQL query.
3. Say how wrong the dashboard is, as a percentage of the true value:
   `(average − fleet) / fleet × 100`.
4. Write `/obs/answers/fleet-p99.txt`:

```
avg_p99_ms=<the dashboard's number, in ms>
fleet_p99_ms=<the fleet p99, in ms>
error_pct=<how far off the average is, in %>
query=<your PromQL for the fleet p99>
```

## What you're being graded on

The check runs your query, which has to return one value within 10% of the
fleet p99 computed from the buckets, and your two numbers must match what
Prometheus says now. `error_pct` must follow from your own two numbers,
within 5 points.

<details>
<summary>Hint 1 — the buckets of one replica</summary>

```
promq 'rate(search_latency_hist_seconds_bucket{replica="d"}[1m])'
```

`histogram_quantile(0.99, ...)` over that gives replica `d`'s p99. Without
the `replica` filter you get four series, one p99 each: still per replica.

</details>

<details>
<summary>Hint 2 — merging</summary>

Add the bucket rates across replicas, keeping only the `le` label:
`sum by (le) (...)`. That is one histogram for the fleet. Take the quantile
of that.

</details>

<details>
<summary>Solution</summary>

```
promq 'histogram_quantile(0.99, sum by (le) (rate(search_latency_hist_seconds_bucket[1m])))'
```

```
avg_p99_ms=490
fleet_p99_ms=1060
error_pct=-54
query=histogram_quantile(0.99, sum by (le) (rate(search_latency_hist_seconds_bucket[1m])))
```

The fleet's p99 is over a second, past the 800ms objective. The dashboard
says half that.

### Why it is so far off

Replicas `a`, `b` and `c` answer in about 80ms with a p99 near 250ms;
replica `d` answers in about 300ms with a p99 near 1.2s. `d` takes 150 of
the 300 requests a second, half the traffic. The slowest 1% of the fleet's
requests is the slowest 2% of `d`'s, about 1.05 seconds. The average gives
`d` a quarter of the weight and pulls the number down towards the three
quiet replicas.

The max of the four p99s, 1.2s, is closer here but also wrong, and wrong
the other way: it would say the same if `d` took one request in a thousand.

### What the histogram costs you

`histogram_quantile` assumes requests are spread evenly inside a bucket,
so its answer is only as fine as the buckets around it: this one falls in
the 1s to 1.5s bucket and is interpolated within it. Put bucket boundaries
near the thresholds you have objectives for. A summary is exact for its one
replica, and useless the moment you need more than one.

</details>
