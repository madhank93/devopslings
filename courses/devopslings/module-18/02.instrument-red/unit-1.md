---
title: "orders has no metrics, so nobody knows it fails one order in twenty"
---

## The situation

orders takes customer orders on `GET /order`. About one order in twenty
fails because the payment provider declines it, and some orders take over a
second. Nobody on the team knows either number. orders has no metrics, so
Prometheus scrapes `orders:9101` and is refused.

The source is `/obs/apps/orders.py`. Saving it restarts orders. Anything it
prints, including a traceback, goes to `/obs/logs/orders.log`.

## RED

For a service that answers requests, three numbers cover most questions
anyone will ask:

- **Rate**: requests per second
- **Errors**: how many of those failed
- **Duration**: how long they took, as a distribution, not an average

With `prometheus_client` (already installed) that is two metrics:

- a `Counter` of requests with a label for the status code. Rate is
  `rate(...)` over all of it, and errors are the series where the code is
  `500`.
- a `Histogram` of request duration. Prometheus calculates percentiles from
  its buckets with `histogram_quantile`.

Three details decide whether those numbers are true:

- **Units.** Prometheus measures time in seconds. A duration metric's name
  ends in `_seconds`, and its values have to be in seconds as well.
- **Buckets.** A histogram only knows how many requests landed in each
  bucket. A percentile inside a bucket is an interpolation, so buckets have to
  cover the range of real request times in several steps. Anything above the
  largest bucket is only known to be "bigger than that".
- **Labels.** Each distinct label value creates a new series, and Prometheus
  keeps every series it has seen in memory. A status code has a handful of
  values. A user ID or request ID has one per request.

## Your objectives

Instrument orders so that it exposes, on port 9101:

```
orders_requests_total{code="200"}           counter, one per request, labelled with the status code sent
orders_request_duration_seconds_bucket{le=…}  histogram of the time to serve each request
```

## What you're being graded on

loadgen sends orders traffic all the time and records what the customers saw:
how many requests, which status codes, how long each took. The check compares
orders' own metrics with loadgen's over the last minute:

- the request count matches what customers sent
- the `code="500"` count matches the errors customers got
- every request is timed, failures included
- the average duration matches what customers waited, in seconds
- the duration spreads over several buckets, and almost none of it is above
  the largest one
- `orders_requests_total` has a handful of series, not one per request

The check waits for a minute of data after orders last restarted, so expect
it to take a minute after each save.

<details>
<summary>Hint 1 — the shape</summary>

```python
from prometheus_client import Counter, Histogram, start_http_server

REQUESTS = Counter("orders_requests_total", "…", ["code"])
DURATION = Histogram("orders_request_duration_seconds", "…")

start_http_server(9101)   # before the main server starts serving
```

In the handler, start a timer before the work, and record both metrics once
the status code is known.

</details>

<details>
<summary>Hint 2 — the failures</summary>

`place_order()` raises on a failed order, and the handler answers 500. Record
the metrics after the `try`/`except`, not inside the `try`, or every failure
skips them.

</details>

<details>
<summary>Solution</summary>

```python
REQUESTS = Counter("orders_requests_total", "Order requests served, by HTTP status code.", ["code"])
DURATION = Histogram("orders_request_duration_seconds", "Time to serve an order request.")
…
    def do_GET(self):
        …
        start = time.perf_counter()
        try:
            place_order()
            code, body = 200, b"ok\n"
        except RuntimeError:
            code, body = 500, b"error\n"
        …send the response…
        DURATION.observe(time.perf_counter() - start)
        REQUESTS.labels(str(code)).inc()

start_http_server(9101)
```

The default buckets run from 5 milliseconds to 10 seconds, which covers
orders' 30 milliseconds to 2 seconds. A service whose requests take minutes,
or microseconds, needs its own.

Now the questions have answers:

```
sum(rate(orders_requests_total[1m]))                                          # rate
sum(rate(orders_requests_total{code="500"}[1m])) / sum(rate(orders_requests_total[1m]))   # error ratio
histogram_quantile(0.99, sum by (le) (rate(orders_request_duration_seconds_bucket[1m])))  # p99
```

### The ways this goes wrong

Each of these produces metrics that look fine on a graph:

- **Counting inside the `try`.** Successes are counted and failures are not,
  so the error rate is zero during an outage.
- **Milliseconds in a `_seconds` metric.** Every value is a thousand times
  too big, and every request lands above the largest bucket.
- **A `Summary` instead of a `Histogram`.** A summary calculates quantiles
  inside the process. You cannot add up the p99 of three instances, or ask for
  a p99 over a different window. A histogram's buckets can be summed and
  re-cut afterwards.
- **Buckets like `[1, 5, 10]`.** Nearly every order is under a second, so
  they all land in one bucket. The p50 and the p99 are both interpolated
  inside it, and both are guesses.
- **A request ID as a label.** One new series per request, forever. That is
  the cardinality lesson later in this module.

</details>
