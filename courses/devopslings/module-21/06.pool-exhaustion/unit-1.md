---
title: "One slow endpoint starves every other endpoint"
---

## The situation

`shop` has two routes:

```
$ curl -s localhost:18091/browse
{"items":["kettle","toaster","lamp"],"status":"ok"}
$ curl -s localhost:18091/checkout
{"elapsed_ms":3,"price":42.0,"status":"ok"}
```

`/browse` is served from memory and never leaves the process. `/checkout` calls
`pricing`. Both are handled by the same pool of 16 worker threads.

At verify time two things happen together. `pricing` slows to 1.5 seconds a
call. It is slow, not broken, and it still answers every request correctly.
And a checkout rush arrives: 100 checkouts a second, alongside a steady 10
browses a second.

Your job: keep `/browse` fast, and keep `/checkout` selling as much as `pricing`
can price.

## Why the route that does nothing slow goes down

A thread that calls `pricing` is held for the whole call. Little's law gives the
number of threads checkout wants at once: arrival rate times time held. That is
100/s × 1.5s = **150 threads**. The pool has 16, so it is full within a fraction
of a second. Every request queues for a thread after that, and a browse request
is in the same queue as the checkout requests.

`/browse` needs nothing from `pricing`, but it does need a thread, and it is
competing for one with every checkout. This is how one slow dependency takes
down a service whose other endpoints have nothing to do with it.

## This is not the timeout lesson

`no-timeout-hangs` fixed a call that waited *forever*. Here no call waits
forever. Pricing answers in 1.5 seconds, which is inside any sane timeout. The
problem is that many reasonable calls happening together use up the pool. A
timeout bounds how long one request can hold a thread. It does nothing about
how many threads one route can hold.

## Your objectives

1. `/browse` stays fast while `/checkout` is flooded and `pricing` is slow.
2. `/checkout` keeps selling what `pricing` can price, instead of failing every
   request to protect the other route.

## What you're being graded on

A k6 load test with both routes running at once, under the fault:

```js
'http_req_duration{route:browse}': ['p(95)<500'],      // browse stays fast
'checks{route:browse}': ['rate>0.99'],                 // and answers
'http_reqs{route:checkout,status:200}': ['count>=40'], // checkout still sells
```

The last line is there because switching checkout off is not a fix. If every
checkout fails, browse is protected and the shop has still lost its revenue.

## How to configure it

`shop` reads three variables from `sandboxes/chaos-stack/.env`:

```
SHOP_THREADS=      # the shared worker pool (this container's limit is 64)
PRICING_TIMEOUT=   # seconds to wait for pricing; 0 = no timeout
PRICING_POOL=      # max threads inside a pricing call at once; 0 = no limit
```

When `PRICING_POOL` is full, a checkout is refused straight away with a `503`
instead of waiting. Leave the `COMPOSE_FILE` line alone: it is what adds `shop`
to the stack. Then apply:

```
docker compose -p devopslings-chaos-stack up -d shop
```

You can reproduce the fault yourself while you experiment:

```
curl -X POST localhost:8474/proxies/pricing/toxics -H 'Content-Type: application/json' \
  -d '{"name":"latency","type":"latency","stream":"downstream","attributes":{"latency":1500}}'
```

<details>
<summary>Hint 1 — more threads</summary>

Set `SHOP_THREADS=64` and run the test. The pool takes a moment longer to fill,
then fills anyway, because checkout wants 150 threads. The number that decides
the outcome is rate × latency, and the fault sets both of those. Whatever pool
you size, a big enough rush or a slow enough dependency will fill it.

</details>

<details>
<summary>Hint 2 — a timeout</summary>

There are two kinds of timeout here, and neither works.

- Above 1.5s, the timeout never fires. Every checkout still holds its thread for
  1.5s.
- Below 1.5s, every pricing call is abandoned. Browse recovers once the timeout
  is short enough, and checkout sells nothing. That is turning a route off, not
  isolating it.

</details>

<details>
<summary>Hint 3 — whose threads are they?</summary>

The ship metaphor is literal. A hull divided into compartments still floods
where it is breached, but the flooding stops at the bulkhead.

Decide how many of the 16 threads checkout's pricing calls are *allowed* to
hold. Pricing can then only use that share of the pool. Whatever is left over
belongs to everything else.

</details>

<details>
<summary>Solution</summary>

`sandboxes/chaos-stack/.env`:

```
SHOP_THREADS=16
PRICING_TIMEOUT=0
PRICING_POOL=8
```

```
docker compose -p devopslings-chaos-stack up -d shop
```

Before, with one shared pool:

```
✗ { route:browse }..........: avg=23.18s  p(95)=30s
✓ { route:checkout,status:200 }: 297
```

After, with a bulkhead:

```
✓ { route:browse }..........: avg=1.39ms  p(95)=3.22ms
✓ { route:checkout,status:200 }: 112
```

Checkout served fewer requests than before: 112 against 297. That is the
bulkhead working as intended. Eight slots at 1.5s each come to about five
checkouts a second, and the rest of the rush is refused immediately rather
than queued. The 297 "successes" before came at the cost of every browse
request in the shop.

### What the bulkhead buys

Without a bulkhead, how bad things get depends on whichever route is having the
worst day. With one, each dependency can only damage its own share of the pool.
A slow `pricing` can still make checkout slow, or make it refuse requests. It
can no longer reach `/browse`, `/health`, or any route that does not call it.

This is the pattern Hystrix made famous with a thread pool per dependency. The
same idea shows up as a semaphore per route, a connection pool per downstream
service, a separate worker deployment for the heavy endpoint, or a Kubernetes
`ResourceQuota`. Each one caps what a single consumer can take from a shared
resource.

### Choosing the size

Size a bulkhead for normal traffic, not for the fault. Use rate × normal latency
plus headroom. On a normal day pricing answers in 5ms, so a handful of slots
covers hundreds of checkouts a second. Fault-day traffic is meant to overflow
it. Make the slots too small and you refuse checkouts on a good day. Make them
too large and no capacity is left over for the other routes. Here, anything
from 4 to 15 of the 16 threads passes. At 3, checkout sells right on the line.

### What this does not fix

The refused checkouts got a fast `503`. Give them a fallback price, as
`no-timeout-hangs` did, and they become sales. A bulkhead also keeps sending
traffic to a pricing service that is clearly struggling. Stopping that is the
circuit breaker's job. The patterns stack: a timeout bounds one call, a
bulkhead bounds one dependency's share, and a breaker stops calling a
dependency that is failing.

</details>
