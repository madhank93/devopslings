---
title: "The request with no timeout that hangs forever"
---

## The situation

`checkout` calls `pricing` on every request. Right now both are healthy:

```
$ curl -s localhost:18090/checkout
{"elapsed_ms":4,"price":42.0,"source":"pricing","status":"ok"}
```

Four milliseconds. Nothing is wrong, and nothing is going to be wrong with
`pricing` — it stays up and correct for this entire lesson.

What is going to happen is that the network between them gets slow. Eight
seconds of latency, injected at verify time. `pricing` will still answer every
request perfectly; it will just take eight seconds to do it.

Your job is to make `checkout` survive that.

## Why this is the failure that takes down companies

A dependency being *down* is the easy case: connections are refused
immediately, you get an error, you handle it. A dependency being *slow* is
worse, because to a caller with no timeout, slow is indistinguishable from
working. Every request holds a worker thread and waits. New requests queue
behind them. Within seconds `checkout` has no free workers, and now `/health`
does not answer either — a service that had nothing to do with pricing is down
because of pricing.

That is a cascading failure, and it is what the AWS S3 outage in 2017 and a
long list of others have in common.

## Your objectives

1. Bound how long `checkout` will wait for `pricing`.
2. Keep answering customers when `pricing` is slow.

Objective 2 is separate from objective 1, and you need both. Read the check
before you start.

## What you're being graded on

A k6 load test with two thresholds:

```js
http_req_duration: ['p(95)<3000'],   // don't hang
checks: ['rate>0.95'],               // and still answer usefully
```

k6 exits non-zero when either is breached, so the load test is the grade. The
second threshold is the one that catches a half-fix: a fast `503` clears the
latency threshold and fails the checks threshold, because a customer who gets
an error page quickly has still not been served.

## How to configure it

`checkout` reads three environment variables. Set them in
`sandboxes/chaos-stack/.env`:

```
PRICING_CONNECT_TIMEOUT=   # seconds to wait for the TCP connect
PRICING_READ_TIMEOUT=      # seconds to wait for the response body
PRICING_FALLBACK=          # price to use when pricing can't be reached
```

Then apply them. Compose reads `.env` when it *creates* a container, so an
edit alone changes nothing:

```
docker compose -p devopslings-chaos-stack up -d
```

You don't need to edit any Python.

<details>
<summary>Hint 1 — what "no timeout" actually means</summary>

Most HTTP clients default to waiting forever. `requests` does:

> `timeout` is not a time limit on the entire response download; ... by default,
> requests do not time out unless a timeout value is set explicitly.

Nothing in TCP will save you. A connection where the peer is alive but slow is
a perfectly healthy connection as far as the kernel is concerned — there is no
error to report, so the socket read simply blocks.

</details>

<details>
<summary>Hint 2 — connect and read are different waits</summary>

Two separate things can be slow:

- **connect** — the TCP handshake. Fails fast when the host refuses, hangs when
  a packet is dropped silently.
- **read** — waiting for the response after the request was sent. This is the
  one this lesson injects.

They deserve different budgets. A connect that has not completed in a second is
not going to complete; a response might legitimately take longer.

</details>

<details>
<summary>Hint 3 — a fast error is still an error</summary>

Set only a timeout and watch what happens:

```
$ curl -s localhost:18090/checkout
{"elapsed_ms":2003,"error":"ReadTimeout","status":"error"}
```

Two seconds instead of eight — the latency threshold passes. And every customer
gets a `503`, so the checks threshold fails.

You have stopped the cascade, which was the important part. Now ask what
`checkout` should do with the request it can no longer price. It has options
other than giving up.

</details>

<details>
<summary>Solution</summary>

`sandboxes/chaos-stack/.env`:

```
PRICING_CONNECT_TIMEOUT=1
PRICING_READ_TIMEOUT=2
PRICING_FALLBACK=39.99
```

```
docker compose -p devopslings-chaos-stack up -d
```

Before:

```
✓ checks..................: 100.00% 40 out of 40
✗ http_req_duration.......: avg=8.01s  p(95)=8.02s
```

After:

```
✓ checks..................: 100.00% 160 out of 160
✓ http_req_duration.......: avg=2.01s  p(95)=2.03s
```

Note the iteration counts: 40 versus 160. The same ten virtual users over the
same fifteen seconds got four times as much work done, because they were not
each parked for eight seconds.

### The two halves

**The timeout bounds the damage.** It converts "wait forever" into "wait two
seconds, then fail", which caps how many workers a slow dependency can consume.
Without it, `checkout`'s failure is unbounded and has nothing to do with how
much traffic *it* is receiving.

**The fallback preserves the service.** A checkout page that shows a slightly
stale price is worth enormously more than one that shows an error. This is
graceful degradation: identify which parts of a response are essential and
which have an acceptable substitute, and design the substitute before you need
it.

Not every call has a sensible fallback. Do not invent one for a payment
authorisation. But for a price, a recommendation, a review count, or a
personalised banner, the honest answer is usually "show something reasonable
and log it", and the reason teams do not is that nobody decided what
"reasonable" was in advance.

### Choosing the numbers

Timeouts are a budget, not a guess. Work backwards from what you promised: if
`/checkout` has a 3-second SLO and calls two services, neither can be allowed
two and a half seconds. Then check the dependency's actual latency
distribution — a timeout below its p99 turns a slow-but-working dependency into
a broken one, and you have caused an outage in the name of preventing one.

A reasonable starting point is somewhere above the dependency's p99 and below
your own budget. If no such number exists, you have found a real architectural
problem, and it is better to find it now than at 3am.

### What this does not fix

The timeout stops `checkout` from hanging. It does not stop it from sending
every single request into an eight-second wait — it still tries, every time,
and still burns two seconds per request doing so. Under real load you would
want to stop calling a dependency that is clearly unhealthy and start again
later, which is what a circuit breaker does, and which is the next lesson.

</details>
