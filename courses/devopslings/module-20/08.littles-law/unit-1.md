---
title: "How many workers month-end needs"
---

## The situation

`render` turns an order into an invoice PDF. Each render spends most of its
time waiting on the PDF service, and it runs `WORKERS` renders at once;
requests beyond that wait in a queue. `WORKERS` is set in
`sandboxes/chaos-stack/.env`, and it is 8.

At month-end, invoices arrive at **150 a second**. Replay it:

```
docker compose exec -T k6 k6 run - < answers/peak.js
```

The latency climbs for the whole run, into seconds. Every month someone
doubles `WORKERS`, it holds or it doesn't, and nobody can say what the right
number is.

## Little's Law

For any system that is not piling up work, over any stretch of time:

```
L = λ × W
```

- **λ** (lambda): the arrival rate, requests per second
- **W**: the time each request spends inside, in seconds
- **L**: the number of requests inside at once, on average

It holds whatever the arrival pattern or the distribution of times, which is
what makes it useful: you need two averages, not a model.

For a worker pool, L is the number of workers busy on average. A pool with
fewer workers than L cannot keep up: each worker finishes `1 / W` requests a
second, so `N` workers finish at most `N / W`, and if that is less than λ the
queue grows for as long as the arrivals last.

## Your objectives

1. Measure **W**, the time one render takes when nothing is queueing.
2. Compute **L** for month-end.
3. Set `WORKERS` from that number, apply it with
   `bash <lesson>/files/deploy.sh`, and run `answers/peak.js` until the p99 is
   under **400ms** with no failures.
4. Write both numbers in `answers/littles-law.txt`:

```
service_time_ms=<W, in milliseconds>
workers_needed=<L>
```

## What you're being graded on

`workers_needed` has to equal 150 × your W, within 10%. `WORKERS` must be no
more than one and a half times `workers_needed`: the point is to size from
the number. The check then runs the lesson's own copy of `peak.js` with your
`WORKERS`, and expects a p99 under 400ms with no failed requests.

<details>
<summary>Hint 1 — measuring W</summary>

A single request on an idle service measures W with no queueing in it:

```
docker compose exec -T checkout python3 -c "import time, urllib.request as u; t=time.time(); u.urlopen('http://localhost:8240/render').read(); print(round((time.time()-t)*1000), 'ms')"
```

Run it ten times and average: a render takes anywhere from 120ms to 280ms. Measuring W
during the month-end test would include the queue, which is the thing you are
trying to size away.

</details>

<details>
<summary>Hint 2 — exactly L is not enough</summary>

L is an average. With exactly L workers, every worker is busy all the time,
and a moment where a few slow renders land together starts a queue that the
pool has no spare capacity to drain. Run the pool at 80 to 85% busy: divide L
by 0.8 or 0.85.

</details>

<details>
<summary>Solution</summary>

W is about 200ms. L = 150 × 0.2 = **30** renders in progress on average.

```
service_time_ms=200
workers_needed=30
```

`.env`:

```
WORKERS=38
```

38 workers at 30 busy on average is 80% utilisation. The month-end run holds a
p99 around 280ms: a slow render plus a little queueing.

### Using it the other way round

Little's Law rearranges to whichever term you are missing:

- **λ = L / W**: a database with 20 connections and 50ms queries can serve at
  most 400 queries a second, however many application servers ask.
- **W = L / λ**: a queue holding 6,000 messages, drained at 200 a second,
  means each message waits about 30 seconds.

The last one is useful in an incident: the depth of a queue and its drain rate
tell you how stale the work at the front is, without any tracing.

### What it does not tell you

The law gives the average, not the tail. How much headroom the tail needs
depends on how variable arrivals and service times are: steady traffic to a
predictable service can run at 90% busy, bursty traffic to a variable one
needs more room. That part you find by running it, which is why the check
runs month-end rather than trusting the arithmetic.

</details>
