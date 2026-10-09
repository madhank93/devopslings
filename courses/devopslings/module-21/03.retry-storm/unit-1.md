---
title: "The retry that turns a blip into an outage"
---

## The situation

The network between checkout and pricing is flaky. About one connection in
twenty gets reset before it reaches pricing. Someone fixed that the usual way,
by retrying, and the fix worked: customers stopped seeing errors.

This lesson runs a variant of checkout called **checkout-retry**, listening on
`:8130`. For every request it calls a metered copy of pricing that answers
exactly like the real one and also counts every request that reaches it. Its
retry policy comes from `sandboxes/chaos-stack/.env`:

```
RETRY_MAX_ATTEMPTS=5               # attempts per request, including the first
RETRY_ON=connect,timeout,5xx,4xx   # which failures get retried
RETRY_BUDGET=0                     # retries allowed per request served; 0 = no limit
```

Each attempt times out after one second, and retries go out immediately.
pricing can do about **50 requests a second**. Customers arrive at 25 a second,
so it is half busy.

At verify time, ten seconds into a load test, the network stalls for five
seconds: every response from pricing arrives too late. Then the stall clears,
and pricing is healthy again.

## What a retry costs

A retry is a second request. When one request in twenty fails, retrying them
adds 5% to pricing's load and nobody notices. When *every* request fails at
once, every request uses all of its attempts. Five attempts turn 25 requests a
second into 125, against a dependency that can do 50.

pricing does not stop working. It queues. Each request now waits behind
hundreds of others, takes longer than checkout's one-second timeout, and gets
retried, while pricing still does the work for the abandoned one. The stall
ends, and nothing improves: the retries alone are more than pricing can serve.

Here is what the check reports with the current policy:

```
customers served correctly — before the stall: 98.8%, after it: 0.4%
pricing received — steady: 36/s, during the stall: 59.3/s, after: 107.4/s (capacity 50/s)
```

A five-second stall became an outage that lasted until the load test stopped.
This is a **metastable failure**: the original trigger is gone, and the system
stays down because of how it reacted to the trigger.

## Your objectives

1. Keep retrying the failures a retry can fix.
2. Stop retrying the failures it cannot.
3. Keep retries from multiplying pricing's load when everything fails at once.

## What you're being graded on

A 30-second k6 load test. The stall lands in the middle. Its thresholds read
pricing's own counters, so what pricing *received* is graded, not what
checkout says it sent:

```js
'checks{phase:steady}': ['rate>0.99'],    // resets are retried and customers never see them
'checks{phase:after}':  ['rate>0.95'],    // after the stall, customers are served again
retried_404:            ['count<1'],      // pricing never sees a request it already answered 404
upstream_amplification: ['value<1.5'],    // pricing's load during the stall / its load before it
```

The customers who arrive *during* the stall are not graded. Some of them will
fail, and that is fine. The fault is real, and no retry policy can make a
five-second stall invisible to the people inside it. What you control is
whether it stays five seconds long.

One customer in ten asks for a SKU that has been retired, and pricing correctly
answers `404`. The check expects checkout to pass that `404` on.

Edit `.env`, then run the check. checkout-retry is restarted with the new
policy each time the check runs, so there is no container to recreate.

<details>
<summary>Hint 1 — not every failure is worth retrying</summary>

Ask of each kind of failure: if I send the identical request again, could the
answer be different?

A connection reset: yes, the next connection is a new one. A timeout: maybe.
A `503`: that is what it is for. A `404` for a SKU that does not exist: no. It
will be a `404` on the fifth attempt too, and the four in between are load you
added for nothing.

</details>

<details>
<summary>Hint 2 — a cap per request is not a cap</summary>

Try `RETRY_MAX_ATTEMPTS=3` with the 4xx fix and no budget. The numbers look
reasonable, and pricing's load still doubles during the stall, to around 50
requests a second, which is its whole capacity. Some runs scrape through and
some never recover. At a slightly higher arrival rate, none would.

`RETRY_MAX_ATTEMPTS` limits how many attempts *one* request makes. It says
nothing about how many requests are failing at the same time. The load it
allows is the arrival rate multiplied by the attempt count, and the moment
that matters is the one where every request fails.

What you want is a limit on retries as a *share of all traffic*: whatever
happens, retries add at most a fixed fraction to pricing's load.

</details>

<details>
<summary>Hint 3 — what RETRY_BUDGET does</summary>

checkout-retry keeps a small pool of retry tokens. Each request it serves adds
`RETRY_BUDGET` tokens, up to a maximum of 10, and each retry spends one. With
no token, there is no retry, and the failure goes back to the customer.

At `0.1`, retries can add about 10% to pricing's traffic on average. That is
plenty for one reset in twenty. When everything fails, the pool drains in a
moment and checkout stops retrying.

</details>

<details>
<summary>Solution</summary>

`sandboxes/chaos-stack/.env`:

```
RETRY_MAX_ATTEMPTS=3
RETRY_ON=connect,timeout,5xx
RETRY_BUDGET=0.1
```

```
customers served correctly — before the stall: 100.0%, after it: 100.0%
pricing received — steady: 25/s, during the stall: 27.7/s, after: 25/s (capacity 50/s)
```

The stall cost the customers who arrived during it their answer, and nothing
else. The extra 2.7 requests a second during the stall are the budget being
spent: the tokens saved up before it go out in the first second, and then
there is nothing more to spend.

### The three changes

**Retry only what a retry can fix.** Connection errors and timeouts are
retryable. So is a `503`, a server saying "not now". A `4xx` means the request
was wrong, and repeating a wrong request gives the same answer. A `429` is the
exception, and it usually comes with a `Retry-After` telling you when. With
`4xx` in the list, every retired-SKU lookup costs pricing five requests.
Before the stall, that alone took it from 25 requests a second to 36.

**Bound retries as a share of traffic.** This is the change that stops the
storm. A per-request limit multiplies: three attempts means up to three times
the load, and that multiple arrives exactly when the dependency is struggling.
A budget adds: retries are at most 10% on top, whether one request is failing
or all of them are. The Google SRE book describes this pair, a per-request
limit plus a per-client retry budget of around 10%. gRPC's retry throttling is
the same idea expressed as a token bucket.

**Keep a per-request limit anyway.** The budget protects pricing. The attempt
limit protects the *customer*: without one, a single request could spend a
minute retrying while its customer waits.

### Why this fails while it works

The original policy was not careless. It fixed a real problem, the flaky
network, and every metric looked better afterwards. Retry storms come from
fixes like that one. The code that causes the outage has been running for
months, and it only shows its cost during the one event it was never tested
against.

That is also why the check needs a fault. Nothing in the steady state
distinguishes a policy that amplifies load from one that does not. You have to
make everything fail at once and watch what the dependency receives.

### What this does not fix

All the retries here go out *immediately*. That was safe for checkout-retry,
because one process holding one budget cannot send many at once. Two hundred
separate clients, each with its own retry loop, can. If they fail at the same
moment and wait the same amount of time, they all come back at the same
moment. That is the next lesson.

</details>
