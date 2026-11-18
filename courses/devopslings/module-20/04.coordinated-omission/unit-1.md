---
title: "The load test that waits politely for the slow answer"
---

## The situation

`search` answers in about 5ms. Every 5 seconds it stops completely for 1
second, the way a stop-the-world garbage collection does: everything in
progress waits for the pause to end, and so does everything that arrives
during it.

The nightly report runs `answers/report.js`, one virtual user sending requests
back to back for 30 seconds:

```
docker compose exec -T k6 k6 run - < answers/report.js
```

```
http_req_duration....: p(50)=6.89ms p(99)=9.18ms max=1.01s
```

A p99 of 9ms. The max shows that the test hit the pause, and the p99 says it
did not matter. Production sees **100 requests a second**, and its customers
say search hangs for a second every few seconds.

## Where the slow requests went

Count them. In each 5-second cycle the report's one user sends about 800
requests in the 4 seconds search is working, and **one** during the pause: it
sends it, waits a second for the answer, and only then sends the next. So
one request in 800 is slow, and the 99th percentile never reaches it.

Production does not wait. Its 100 customers a second keep arriving through the
pause, so about 100 requests in each cycle arrive while search is stopped, and
on average each waits half a second. That is one in five.

The load generator was coordinating with the system it was measuring: when
search slowed down, the test slowed down with it and stopped sending the
requests that would have recorded the slowness. Gil Tene named this
**coordinated omission**. The latency it reports is the latency of a client
that never has to wait for anyone, which is not a client you have.

## Closed and open models

- **Closed model**: a fixed number of users, each sending its next request when
  the last one returns. Arrivals slow down when the system does. k6's `vus` and
  `duration`, `constant-vus`, `ramping-vus` and `per-vu-iterations` are all
  closed.
- **Open model**: requests arrive on a schedule, whatever the system is doing.
  k6's `constant-arrival-rate` and `ramping-arrival-rate` are open. k6 starts a
  new request on time even when earlier ones are still waiting, as long as it
  has a VU free, so give it enough: `maxVUs`.

Public traffic, where customers do not know about each other, is open. A
closed test of an open system leaves out exactly the requests you need.

## Your objectives

1. Write `answers/open.js`: a k6 test that sends production's 100 requests a
   second to `http://checkout:8200/search` for at least 20 seconds, open
   model.
2. Run both tests and record the p99 of each in
   `answers/coordinated-omission.txt`:

```
closed_p99_ms=<p99 from report.js>
open_p99_ms=<p99 from open.js>
```

## What you're being graded on

The check confirms `answers/open.js` uses an arrival-rate executor, runs both
tests itself, and expects your open test to see a p99 of at least 400ms. Your
two numbers have to agree with what it measured: the closed one well under a
second, the open one within about a third of the check's own run.

<details>
<summary>Hint 1 — more users</summary>

Raising `vus` to 100 does not fix it. Each of the 100 users still waits for its
answer, so during the pause the test sends 100 requests and then nothing, while
outside the pause it sends thousands. The slow share stays tiny. The number of
users is the wrong variable: the rate of arrivals is the one that has to stay
fixed.

</details>

<details>
<summary>Hint 2 — the executor</summary>

```js
export const options = {
  scenarios: {
    production: {
      executor: 'constant-arrival-rate',
      rate: 100, timeUnit: '1s', duration: '30s',
      preAllocatedVUs: 50, maxVUs: 300,
    },
  },
};
```

</details>

<details>
<summary>Solution</summary>

`answers/open.js`:

```js
import http from 'k6/http';

export const options = {
  scenarios: {
    production: {
      executor: 'constant-arrival-rate',
      rate: 100, timeUnit: '1s', duration: '30s',
      preAllocatedVUs: 50, maxVUs: 300,
    },
  },
  summaryTrendStats: ['p(50)', 'p(99)', 'max'],
};

export default function () {
  http.get('http://checkout:8200/search');
}
```

```
http_req_duration....: p(50)=7.27ms p(99)=968.02ms max=1s
```

`answers/coordinated-omission.txt`:

```
closed_p99_ms=9
open_p99_ms=968
```

The median barely moved. The p99 is a hundred times worse, and it is the
honest one: one request in five arrives during a pause and waits for it, so
the p99 is almost the whole pause.

### Telling which kind of number you have

A report from a closed-model tool is not wrong about the requests it sent. It
just did not send the requests that would have been slow. Ways to spot it:

- The max is far above the p99, and the request count in a slow run is lower
  than in a fast one.
- The test's throughput moves with the service's latency. An open test sends
  the same number of requests whatever happens.

Some tools correct for it after the fact. HdrHistogram's
`recordValueWithExpectedInterval` fills in the requests that should have been
sent during a stall, and wrk2 schedules requests at a fixed rate the way
`constant-arrival-rate` does. Correcting afterwards is a reconstruction.
Sending on a schedule measures it directly.

### Where closed is right

Some systems really are closed: a batch job with a fixed pool of 8 workers, or
a connection pool that only ever has 20 queries in flight. There, the next
request genuinely waits for the last one, and a closed test is the accurate
model. The question is whether your real callers wait for each other. Public
traffic does not.

</details>
