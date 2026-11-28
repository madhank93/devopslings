---
title: "somewhere between 250 and 500"
---

## The situation

The search service's SLO: 99% of queries answer in under 300 ms. Its
latency histogram goes over OTLP to `prometheus-2`, with buckets at 50, 100,
250, 500 ms, 1 s and 2.5 s. The SLO dashboard's p99:

```
PROM=http://prometheus-2:9090 promq 'histogram_quantile(0.99, sum by (le) (rate(search_request_duration_seconds_bucket[1m])))'
```

About 450 ms. Is the SLO missed by a little or by half? The buckets cannot
say. Every query between 250 and 500 ms lands in one bucket, and
`histogram_quantile` assumes they are spread evenly across it. The real
queries in that bucket are all between 300 and 340 ms (`one_query()` in
`/obs/apps/lab.py`), and the true p99 is 332 ms.

Adding a 300 ms bucket fixes the 300 ms question. The next SLO someone writes
is 400 ms, or the latency shifts, and the same thing happens at another
boundary.

## Native histograms

A **native histogram** (in OpenTelemetry, an **exponential histogram**) has
no hand-picked boundaries. Its buckets grow by a fixed factor, so every
bucket is the same few percent wide relative to its value, from microseconds
to minutes. With a factor of about 1.09, any quantile is within a few
percent of the truth wherever it falls. The whole histogram is one series
(`search_request_duration_seconds`, no `_bucket`, no `le`), and the bucket
layout only covers ranges that have data, so it is often cheaper than a
classic histogram with fine buckets.

It has to be on at both ends:

- **the producer** has to send one. In the OpenTelemetry SDK that is the
  histogram's aggregation: `ExponentialBucketHistogramAggregation` instead
  of `ExplicitBucketHistogramAggregation`. (For a scraped Go or Java app it
  is the client library's native-histogram option, exposed over the
  protobuf scrape format.)
- **Prometheus** has to accept it. In Prometheus 3.5 native histograms are
  still behind `--enable-feature=native-histograms`. Without it, samples
  arrive and are refused.

Queries change shape too: no `by (le)`, and no `_bucket`:

```
histogram_quantile(0.99, sum(rate(search_request_duration_seconds[1m])))
```

## Your objectives

1. Make search send its latency as an exponential histogram.
2. Make prometheus-2 store it as a native histogram.

Saving `/obs/apps/lab.py` or `/obs/prometheus-2/run.sh` restarts that
process; their output is in `/obs/logs/lab.log` and
`/obs/logs/prometheus-2.log`.

## What you're being graded on

- prometheus-2 has a native histogram named `search_request_duration_seconds`
- its p99 over one minute is within 5% of 332 ms, three times in a row

<details>
<summary>Hint 1</summary>

In lab.py, the `View` picks the aggregation. In run.sh, the flags are a list;
add one.

</details>

<details>
<summary>Solution</summary>

`/obs/apps/lab.py`:

```python
from opentelemetry.sdk.metrics.view import ExponentialBucketHistogramAggregation, View
...
latency_view = View(
    instrument_name="search.request.duration",
    aggregation=ExponentialBucketHistogramAggregation(),
)
```

`/obs/prometheus-2/run.sh`, one more flag:

```
  --enable-feature=native-histograms
```

The default maximum of 160 buckets lets the SDK keep a fine scale over the
range this service sees; Prometheus caps the scale at 8 (a factor of
2^(1/256)) on the way in.

### The ways this goes wrong

- **A 300 ms bucket.** The p99 moves from one wrong number to another:
  the tail is now all in 300-500 ms, interpolated evenly.
- **Only the flag.** Nothing changes: the SDK still sends explicit buckets.
- **Only the SDK.** prometheus-2 refuses every histogram sample, and the
  metric stops updating.
- **The classic query on the native series.** `..._bucket` and `by (le)`
  match nothing now; the dashboard goes blank, not wrong. Change the
  queries with the metric.
- **A tiny `max_size`.** Too few buckets force a coarse scale, and the
  answer is as rough as the classic one.

</details>
