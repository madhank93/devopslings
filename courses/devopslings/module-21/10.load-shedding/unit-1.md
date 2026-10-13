---
title: "Degrading on purpose beats collapsing by accident"
---

## The situation

`api` serves two routes. `/checkout` takes payment. `/recommendations` fills
the "you might also like" strip on the page, which renders fine without it.

Every request, on either route, costs 50ms of CPU, and `api` has 2 cores. So it
can finish **40 requests a second**. On a normal day it sees about 15 checkouts
and 15 recommendation calls a second, and it is a little over a third busy.

At verify time a surge arrives for 20 seconds: still 15 checkouts a second, and
105 recommendation calls. That is 120 a second, three times capacity. Nothing
is broken. There is just more work than the machine can do, and it is going to
fail some of it. The only question is which.

Here is what the check reports with the current settings:

```
checkout — served: 31.0%, p99: 5000ms
recommendations — served: 774 of 2100, p99: 5000ms (refusals included)
```

Checkout needs 15 of the 40 requests a second. It fits with room to spare, and
it failed two times in three anyway.

## Why everything fails at once

Every request joins one queue. It fills at 120 a second and drains at 40, so it
grows by 80 every second, and every request in it waits behind all the ones
before it. A few seconds into the surge, the wait is longer than any client
will hold on for. Clients time out, but `api` does not know that. It goes on to
spend CPU on requests nobody is waiting for any more, while the ones that are
still waiting fall further behind.

This is how overload turns into collapse. Throughput stays at 40 a second the
whole time, and almost none of it reaches anyone.

## Your objectives

1. Checkout is served, at normal speed, through the surge.
2. The excess is refused straight away, not after a wait.
3. Recommendations still get whatever capacity checkout leaves spare.

## What you're being graded on

A 20-second k6 load test at three times capacity:

```js
'checks{route:checkout}':                       ['rate>0.99'],  // checkout is served
'http_req_duration{route:checkout}':            ['p(99)<500'],  // at normal speed
'http_req_duration{route:recommendations}':     ['p(99)<500'],  // refusals are fast
'http_reqs{route:recommendations,status:200}':  ['count>=150'], // degraded, not off
```

## How to configure it

`api` reads four settings from `sandboxes/chaos-stack/.env`:

```
API_WORKERS=16       # requests processed at once; the rest wait for a worker
QUEUE_TIMEOUT_MS=0   # 503 a request that has waited this long; 0 = wait forever
SHED_ALL_AT=0        # 503 any request that arrives with this many in flight; 0 = never
SHED_LOW_AT=0        # same, for /recommendations only; 0 = never
```

"In flight" counts every request `api` has accepted and not yet answered,
whether it is waiting or running. The two `SHED_` checks happen on arrival,
before a request joins any queue.

Edit `.env`, then run the check. `api` is redeployed with the new settings each
time the check runs, so there is nothing to restart.

<details>
<summary>Hint 1 — more workers</summary>

Set `API_WORKERS=64` and run the check. Nothing changes. A worker is a request
in progress, not a core. The extra workers all wait for the same 2 cores, so the
queue just moves from in front of the workers to in front of the CPU. Capacity
is 40 a second however you arrange the waiting.

</details>

<details>
<summary>Hint 2 — a timeout, or a limit</summary>

Both of these work, in the sense that the queue stops growing.
`QUEUE_TIMEOUT_MS` fails whatever has waited too long, and `SHED_ALL_AT` refuses
whatever arrives while `api` is full. Latency comes back down.

Now look at who gets refused. Seven arrivals in eight are recommendations, and
neither setting can tell a recommendation from a checkout. Checkout loses the
same two-thirds of its requests as everything else. The service has stopped
collapsing, and it is still failing the one route that matters.

</details>

<details>
<summary>Hint 3 — what to refuse first</summary>

Decide which traffic you will give up when there is too much. Refuse that
traffic first, and refuse it *early*, while there is still capacity left for
the rest. `SHED_LOW_AT` is that earlier line. Below it, everything is admitted.
Above it, only checkout is.

Every request admitted ahead of a checkout is time that checkout spends
waiting. So set the line low enough to keep that queue short.

</details>

<details>
<summary>Solution</summary>

`sandboxes/chaos-stack/.env`:

```
API_WORKERS=16
QUEUE_TIMEOUT_MS=0
SHED_ALL_AT=0
SHED_LOW_AT=6
```

```
checkout — served: 100.0%, p99: 172ms
recommendations — served: 497 of 2100, p99: 168ms (refusals included)
```

Every checkout was served, in under 200ms. Recommendations got about 25 a
second, which is exactly what checkout left spare. The other 1600 were refused
in a millisecond with a `503`, and the page rendered without the strip.

### Load shedding, and why it needs a priority

Shedding means refusing work on purpose so that the work you do accept gets
done properly. A refusal costs almost nothing. A request that sits in a queue
until its client gives up costs a slot in the queue, then CPU, and still fails.

A single limit, whether `SHED_ALL_AT` or a queue timeout, stops the collapse,
but it sheds at random. Whatever the traffic mix happens to be is what gets
dropped. The production versions of this pattern all add a priority. Google
tags every RPC with a *criticality* and sheds the sheddable ones first. Netflix
puts each request into a priority bucket at the edge and drops from the bottom
as load rises. Envoy's admission control and Kubernetes API Priority and
Fairness do the same thing at the proxy and the control plane.

### Choosing the line

At 40 requests a second, each request in flight is about 25ms of queue for
whatever arrives behind it. `SHED_LOW_AT=6` keeps a checkout's wait to about
150ms. Raise it to 20 and checkout's p99 passes 500ms. Lower it to 1 and checkout
gets an almost empty queue, but recommendations get one core between them. The
right number depends on how long the important traffic can afford to wait.

There is no need for `SHED_ALL_AT` here, because checkout alone fits. On a day
when checkout alone is more than capacity, you need a second, higher line that
sheds checkout too. Better to serve 40 checkouts a second properly than to
accept 60 and serve none of them.

### What this does not fix

The 503s go back to callers that might retry them. A `retry-storm` client would
send each refused recommendation two or three more times, and the surge gets
bigger. Shed responses should tell the caller not to retry straight away:
`Retry-After`, or a status code its retry policy treats as final.

</details>
