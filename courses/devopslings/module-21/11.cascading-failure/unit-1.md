---
title: "One slow dependency takes down three healthy services"
---

## The situation

Four services, one chain:

```
             ┌─ /account ─── (answered by gateway itself)
k6 ─ gateway ┼─ /product ─── product ── /reviews ── reviews
             └─ /checkout ── orders ─── /stock ──── product
```

`gateway` has 16 worker threads, and `orders` and `product` have 8 each. A
request waits for a free thread before it is handled. Traffic is steady: 40
product pages, 20 checkouts and 10 account pages a second.

`reviews` fills a widget on the product page. It is fast most of the time, but
one lookup in ten is for a product with a long history and takes 300ms. If the
call fails, `product` renders the page without the widget.

At verify time, 8 seconds into a 25-second load test, `reviews` slows down by 3
seconds a call and stays slow. Nothing else changes. Here is what the check
reports with the current settings:

```
/account  — answered: 61.2%, p95: 5000ms
/checkout — answered: 33.9%, p95: 5000ms
/product  — answered: 32.1%, p95: 5000ms; with reviews before the fault: 100.0%
requests that waited over 0.5s for a thread — gateway: 581, orders: 312, product: 683
```

`/account` calls nothing. `/checkout` never touches reviews. Both are down.

## How it spreads

Follow the threads, one hop at a time:

1. **product.** 40 pages a second, each holding a thread for 3 seconds, want 120
   threads. product has 8, and they are all gone within a quarter of a second.
2. **orders.** Every checkout calls product's `/stock`. That takes 5ms, but
   first it has to wait for one of product's threads, behind the product pages.
   The orders thread waits too, and orders runs out of threads.
3. **gateway.** Its threads are now waiting on product pages and on checkouts.
   When all 16 are in use, `/account`, which needs nothing but a thread, waits
   behind them.

Each of these services is healthy. Each one failed because it waited, without
limit, on the service below it. That is a **cascading failure**: the fault
moves up the call graph one caller at a time, and every caller that waits is
one more service that goes down.

## Your objectives

1. `/account` and `/checkout` stay fast and correct while reviews is slow.
2. The product page keeps rendering, without reviews if it has to.
3. On a normal day, the product page still shows reviews.

## What you're being graded on

```js
'checks{route:account}':             ['rate>0.99'],  // never noticed
'http_req_duration{route:account}':  ['p(95)<500'],
'checks{route:checkout}':            ['rate>0.99'],  // never noticed
'http_req_duration{route:checkout}': ['p(95)<500'],
'checks{route:product}':             ['rate>0.95'],  // still renders
reviews_shown_before_fault:          ['rate>0.97'],  // with reviews, before the fault
```

## How to configure it

Every call from one service to another has two settings in
`sandboxes/chaos-stack/.env`, named after the hop:

```
<CALLER>_TO_<CALLEE>_TIMEOUT=0   # seconds to wait for an answer; 0 = forever
<CALLER>_TO_<CALLEE>_POOL=0      # calls in flight at once on this hop; 0 = no limit
```

There are four hops: `GATEWAY_TO_PRODUCT`, `GATEWAY_TO_ORDERS`,
`ORDERS_TO_PRODUCT` and `PRODUCT_TO_REVIEWS`. A call that finds its pool full
fails at once, without waiting.

Edit `.env`, then run the check. The services are redeployed with the new
settings each time the check runs. You can slow reviews down yourself while you
experiment:

```
curl -X POST localhost:8474/proxies/cascade-reviews/toxics -H 'Content-Type: application/json' \
  -d '{"name":"slow","type":"latency","stream":"downstream","attributes":{"latency":3000}}'
```

<details>
<summary>Hint 1 — a timeout at the front door</summary>

The obvious place for a timeout is the gateway, where the user is waiting. Set
`GATEWAY_TO_PRODUCT_TIMEOUT=1` and `GATEWAY_TO_ORDERS_TIMEOUT=1` and run the
check. `/checkout` still fails.

A timeout stops the *caller* waiting. It does nothing for the work it gave up
on. product's 8 threads are still held for 3 seconds each by calls the gateway
abandoned long ago, and orders' stock checks are still queued behind them. The
gateway now fails fast instead of slowly, and it still fails.

</details>

<details>
<summary>Hint 2 — a timeout at the right hop</summary>

Move the timeout down to where the slowness comes in, `PRODUCT_TO_REVIEWS`. To
keep reviews on a normal day it has to stay above the 300ms that one lookup in
ten takes. At 0.5s, 40 pages a second each holding a thread for half a second
want 20 threads. product has 8.

A timeout limits how long each call holds a thread, not how many calls hold
one. Under enough traffic, that is still all of them.

</details>

<details>
<summary>Hint 3 — whose threads are they?</summary>

This is `pool-exhaustion` again, one hop down. Decide how many of product's 8
threads calls to reviews are *allowed* to hold. Then the rest always belong to
`/stock`, and to product pages that render without reviews.

Put the limit on the hop where the fault enters. A limit higher up protects the
service that sets it and leaves every other caller of product exposed.

</details>

<details>
<summary>Solution</summary>

`sandboxes/chaos-stack/.env`:

```
PRODUCT_TO_REVIEWS_TIMEOUT=0.6
PRODUCT_TO_REVIEWS_POOL=6
```

All the other hops stay at `0`.

```
/account  — answered: 100.0%, p95: 4ms
/checkout — answered: 100.0%, p95: 16ms
/product  — answered: 100.0%, p95: 607ms; with reviews before the fault: 99.4%
requests that waited over 0.5s for a thread — gateway: 0, orders: 0, product: 0
```

Reviews was slow for 17 seconds. The only thing anyone saw was product pages
without the reviews widget.

### Contain it where it enters

The two settings sit on the one hop that touches the slow dependency, and each
does a different job.

- **The pool is the bulkhead.** Calls to reviews can hold 6 of product's 8
  threads, never more. However slow reviews gets, product keeps 2 threads for
  `/stock` and for pages that render without reviews — both take milliseconds,
  so 2 is plenty.
- **The pool has to fit a normal day.** 40 pages a second at about 50ms each
  is two calls in flight on average, and bursts go well above that. A call that
  finds the pool full is refused, not queued, so a pool of 4 already turns away
  a few percent of healthy lookups before anything is slow. Every service above
  product is protected without being configured, because product never stops
  answering them.
- **The timeout keeps the bulkhead moving.** Without it, each of the 6 slots is
  held for the full 3 seconds. With it, a slot comes back after 0.6s. 0.6 is
  high enough not to cut off the normal 300ms lookups, and a slow reviews still
  costs at most 6 threads.

Limits on the hops above product would not have helped. They stop a caller
from waiting, but the work it abandoned still holds product's threads.

### The patterns stack

This lesson needed no new mechanism. A timeout bounds one call. A bulkhead
bounds how much of a service one dependency can take. A fallback (product's
page without reviews) turns a failed optional call into a smaller page instead
of an error. A circuit breaker on the same hop would stop calling reviews
altogether once it is clearly failing, which gives the slots back sooner still.

What makes it a deep problem is the *placement*. Every service in a chain needs
the same question asked of every call it makes: if this dependency hangs, how
much of me does it take with it? The answer has to be "a bounded share" at
every hop, because the hop you leave unbounded is where the cascade starts.

</details>
