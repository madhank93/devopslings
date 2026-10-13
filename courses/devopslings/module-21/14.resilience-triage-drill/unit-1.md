---
title: "checkout failed its game day, and every pattern is switched on"
---

## The situation

```
SLOs:
  FAIL  outage_calls  value<=20
  ok    checks{phase:after}  rate>0.95
  ...
```

checkout failed its game day — the replay of last month's pricing incident.
That is the entire ticket, and it will be the entire ticket every time you run
this lesson, because the setting that broke is drawn at random from five.

**shop** serves `/checkout`, which calls pricing, and `/browse`, which does not,
from 16 worker threads. It has everything this module built: a read timeout, a
bulkhead, retries, a circuit breaker and a fallback price. Its settings are in
`sandboxes/chaos-stack/.env`:

```
PRICING_TIMEOUT       seconds to wait for pricing's answer; 0 = no limit
PRICING_POOL          most requests inside a pricing call at once; 0 = no cap
FALLBACK_PRICE        the price served when pricing cannot answer; empty = 503
RETRY_MAX_ATTEMPTS    attempts per pricing call, including the first
RETRY_ON              which failures are retried: connect, timeout, 5xx, 4xx
BREAKER_THRESHOLD     consecutive failures before the breaker opens; 0 = none
BREAKER_COOLDOWN_S    how long it stays open before one trial call
RECS_URL              recommendations, for /browse
```

Every setting was right. Then exactly one was changed to something plausible,
and the game day started failing.

The game day is 42 seconds of load with the incident replayed under it:

| phase | time | load | what the network does |
|---|---|---|---|
| steady | 0–8s | 20 checkouts/s | 5% of connections to pricing are reset |
| rush | 8–18s | 40 checkouts/s | pricing answers, in 1.5s |
| outage | 18–28s | 20 checkouts/s | pricing hangs: 8s per call |
| after | 28–42s | 20 checkouts/s | pricing is healthy again |

Browse runs at 10 a second throughout. Pricing in this lesson is a metered copy
that counts every request it receives, per phase.

The report also says, every run, that recommendations failed on every browse.

## Your objectives

- Make the game day pass by repairing **the one setting** that was broken —
  and nothing else
- Write `scratch/resilience-triage-drill/triage.md`, three lines:

  ```
  cause:     <what was wrong, in a few words>
  evidence:  <the counter or number in the report that proved it>
  detection: <a signal and a threshold that would have paged first>
  ```

Run `scratch/resilience-triage-drill/gameday` to replay it (about a minute).
shop is restarted from `.env` each time, so there is nothing else to apply.

## What you're being graded on

The check runs the game day. Its k6 thresholds are the grade, and two of them
read pricing's own counters rather than anything shop reports:

```js
'checks{phase:steady}': ['rate>0.99'],            // resets retried; pricing's answer
'checks{phase:rush}':   ['rate>0.99'],            // every customer gets a price
'checks{phase:outage}': ['rate>0.99'],
'checks{phase:after}':  ['rate>0.95'],            // pricing's answer again, from 36s
'http_req_duration{route:checkout}': ['max<3000'],// nobody waits past the budget
'http_req_duration{route:browse}':   ['p(95)<500'],
rush_sold:    ['count>=30'],                      // slow is not broken
retried_404:  ['count<1'],                        // pricing's counter
outage_calls: ['value<=20'],                      // pricing's counter, while hung
```

It also refuses:

- **more than one setting changed** from how the scenario left them —
  retuning everything to known-good values passes without knowing which one it
  was, and that is the part being drilled
- **`RECS_URL` changed**, and a breaker that opens on one or two failures

And `triage.md`: `cause` must describe the setting that was broken (and only
that one); `evidence` must be the number in the report that proves it;
`detection` must name a signal that fits it *and* a number.

<details>
<summary>Hint 1 — read the report in order</summary>

The first table is what customers got, per phase; the second is what shop did
about pricing; the third line is what pricing itself received.

1. Which SLO failed, and in which phase?
2. In that phase: did checkout answer slowly, answer with an error, or answer
   fine while something else suffered?
3. What did pricing receive — more than shop had orders? Calls while hung?
4. Is the setting that governs that behaviour a value that would ever act on
   *this* incident?

</details>

<details>
<summary>Hint 2 — the shape of each failure</summary>

- **slowest in the outage ≈ 8s, 0 timeouts, breaker never opened**: nothing
  failed. The call waited out the hang and succeeded late.
- **a 503 column**: shop refused or gave up fast — and had nothing to answer
  with.
- **pricing received more than shop had orders, in steady**: something asked
  twice. Pricing counts requests that come back after a 404.
- **pricing received ~40 calls while hung, breaker opened 0 times**: each call
  paid the timeout to learn what the last one had.
- **browse slow while its handler took milliseconds**: browse waited for a
  thread, and every thread was inside a pricing call.

</details>

<details>
<summary>Hint 3 — the arithmetic</summary>

A timeout bounds nothing if it is longer than the wait it guards against, and
the worst case is a sum. A bulkhead protects the other routes only if it is
narrower than the pool it sits in. A breaker that needs more failures in a row
than an outage produces is not there. A 404 is an answer.

</details>

## What actually happened

| Fault | What was changed | What the report shows | The tell |
|---|---|---|---|
| timeout | `PRICING_TIMEOUT=30` | outage slowest 8.0s; max<3000 fails | 0 timeouts, breaker opened 0 times: nothing ever failed |
| fallback | `FALLBACK_PRICE=` (empty) | hundreds of 503s in rush and outage | they match `pool refused` and `breaker refused` exactly |
| retry | `RETRY_ON=connect,5xx,4xx` | retried_404 fails | pricing received more than shop had orders; repeats after 404 > 0 |
| breaker | `BREAKER_THRESHOLD=50` | outage_calls fails | ~40 received while hung, dozens of timeouts, breaker opened 0 times |
| bulkhead | `PRICING_POOL=16` | browse p95 fails | `pool refused` is 0 in the rush; browse handler fast, browse slow |

The red herring, every run: recommendations fail on every browse. The service
was decommissioned; its proxy refuses connections, instantly, and browse serves
bestsellers as it was designed to. A refused connection costs microseconds and
holds nothing. It is the loudest line in the report and the only thing in it
that is working exactly as intended.

<details>
<summary>Solution</summary>

Put the one setting back to a value that acts on this incident:

```
timeout:   PRICING_TIMEOUT=2      over pricing's 1.5s slow, under the 3s budget
fallback:  FALLBACK_PRICE=39.99
retry:     RETRY_ON=connect,5xx
breaker:   BREAKER_THRESHOLD=5
bulkhead:  PRICING_POOL=8         half of shop's 16 threads
```

Then, for example:

```
cause: BREAKER_THRESHOLD=50 is more failures in a row than the outage produced, so the breaker never opened
evidence: pricing received 40 calls while hung; breaker opened 0 times while timeouts climbed
detection: calls to pricing while its error rate > 50% for 30 seconds, with the breaker closed
```

</details>

## Carrying this forward

- **Read what failed before what is configured.** Each fault leaves a different
  shape — late, refused, repeated, unrelenting, starved — and the report showed
  which before you opened `.env`.
- **Count at the dependency.** Two of these five fail only on a counter
  pricing keeps. Customers of a retried 404 or an unbroken outage still got
  an answer.
- **A setting is only right relative to the incident.** Every broken value here
  is reasonable in isolation: a generous timeout, a breaker that does not flap,
  a pool as big as the threads. What makes it wrong is the failure it meets.
- **The loud thing is often the healthy thing.** A dependency that refuses
  instantly is behaving perfectly.

Run the lesson again. The setting moves, and the order you read the report in
does not.
