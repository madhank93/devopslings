---
title: "Synchronised retries from 200 clients"
---

## The situation

Two hundred dashboards show a live price. Each one long-polls a feed on
pricing: it asks, the feed holds the connection for four seconds, then
answers, and the dashboard asks again. Registering a poll costs the feed
about 10ms of serialised work, so it can take on roughly **100 new polls a
second**. In normal running it gets about 45.

The retry policy follows the previous lesson: attempts are bounded and
nothing retries immediately. It lives in `sandboxes/chaos-stack/.env`:

```
RETRY_MAX_ATTEMPTS=6     # attempts per poll, including the first
RETRY_BACKOFF_MS=500     # first retry waits this long; each later one waits twice as long
RETRY_JITTER=none        # none | full | equal
```

At verify time, ten seconds in, the network drops every connection at once
and stays down for one second. Then it is back, and the feed is fine.

## What happens

Every client sees its poll fail at the same instant. Every client then waits
500ms, finds the network still down, and waits a second. Every client then
retries at the same moment, 1.5 seconds after the drop, and the feed takes 194
new polls in a single tenth of a second.

At 100 a second, the feed needs two seconds to register them all. Each client
waits five seconds for an answer: four seconds of hold plus one second of
slack. The back half of the wave waits more than a second in the queue, times
out, and retries, again all at the same moment, so the wave returns:

```
feed arrivals, per 500ms from the moment of the drop:
  1 0 0 200 0 0 0 0 0 0 0 19 48 21 0 0 0 112 0 6 29 42 11 0 0 21 41 28 23 36
busiest 100ms: 194 arrivals, 1.5s after the drop (a normal 100ms: 4.9)
dropped polls answered within 21.7s at p95; polls that gave up: 0
```

Clients that should have reconnected in about five seconds took up to
twenty-two. The 112 at 8.5 seconds is the second wave: the clients that timed
out in the first one, still in step.

Backoff was supposed to prevent this, and it does slow each client down. But
it slows all of them down *by the same amount*, so the clients stay in step,
because they all failed at the same moment. A fixed delay keeps them in step,
and so does a longer one. Exponential backoff keeps them in step too, with
longer gaps between the waves.

## Your objectives

1. Get every dropped poll answered, and quickly.
2. Make the clients' retries arrive spread out rather than in waves.
3. Keep attempts bounded.

## What you're being graded on

A 30-second k6 run of 200 clients with the drop in the middle. The herd is
measured where it lands: `teardown()` reads the feed's own arrival log.

```js
gave_up:         ['count<1'],      // every dropped poll eventually gets its answer
recovery_ms:     ['p(95)<10000'],  // from the drop to the answer, including the 4s hold
herd_peak_ratio: ['value<15'],     // busiest 100ms after the drop / a normal 100ms
```

`RETRY_MAX_ATTEMPTS` must also be between 1 and 10. That is read from the
config rather than measured, because a one-second fault cannot show what an
unbounded retry loop does in a ten-minute one.

The load test reads `.env` each time the check runs, so there is nothing to
restart.

<details>
<summary>Hint 1 — longer backoff is not the fix</summary>

Try `RETRY_BACKOFF_MS=2000`. The waves get further apart, and every one of
them is just as tall: all 200 clients come back inside the same half-second,
and the slowest now take 28 seconds to get an answer.

The trouble is not how long the clients wait. They all wait *the same* time,
counted from *the same* moment.

</details>

<details>
<summary>Hint 2 — make each client wait a different amount</summary>

If each client picked its delay at random, the wave would spread across the
whole backoff window instead of landing in one instant. That randomness is
called **jitter**. `RETRY_JITTER` offers two kinds:

- `full`: wait a random time between zero and the backoff delay.
- `equal`: wait half the backoff delay, plus a random time up to the other half.

</details>

<details>
<summary>Hint 3 — jitter needs attempts to spend</summary>

Full jitter can produce a delay close to zero, and a delay close to zero
during a one-second outage is a wasted attempt. Cut the attempts to three with
full jitter, and about 200 polls run out of attempts before the network comes
back. Jitter spreads the retries over time, so leave enough attempts for that
time to cover the outage.

</details>

<details>
<summary>Solution</summary>

`sandboxes/chaos-stack/.env`:

```
RETRY_MAX_ATTEMPTS=6
RETRY_BACKOFF_MS=500
RETRY_JITTER=full
```

```
feed arrivals, per 500ms from the moment of the drop:
  0 0 104 31 36 17 1 4 5 2 17 46 38 46 38 7 2 4 8 29 49 36 39 28 6 2 5 20 32 46
busiest 100ms: 34 arrivals, 1.1s after the drop (a normal 100ms: 4.6)
dropped polls answered within 7.5s at p95; polls that gave up: 0
```

The busiest tenth of a second went from 194 polls to about 25–35, depending on
the random draws. The feed is still
overloaded for a moment, since 200 clients reconnecting within a second is
more than it can register in a second. But the overload is small enough that
almost nobody waits past their timeout, so there is no second wave.

### Why jitter works

The clients synchronised because they shared two things: the moment they
failed, and the arithmetic they used afterwards. You cannot stop them failing
together, because the network decides that. Jitter removes the second thing,
so each client's delay depends on its own random draw and not just on the
shared clock.

Marc Brooker's AWS article "Exponential Backoff and Jitter" simulates exactly
this and compares strategies. Full jitter finished the work with the fewest
calls. Equal jitter did a little worse, because half of every delay is still
identical across clients. You can see that here: with `equal`, the peak was
43 and p95 recovery was 12 seconds, which misses the 10-second threshold.

### Exponential is still doing work

Jitter decides *where* in the window a retry lands. The exponential growth
decides how big the window is. The first window is small and the next ones
double, so a client that is unlucky twice gets more room each time. A fixed
window with jitter spreads the first retry and then keeps the same crowding
on every attempt after it.

### Where else this shows up

Any time many clients share a clock, they are one event away from a herd. That
covers clients reconnecting after a deploy, caches that all expire on the hour,
cron jobs at `0 * * * *`, and leases renewed on a fixed interval. The fix is
the same each time: add randomness to *when*, so that a shared cause does not
produce a shared moment. A cron job that runs at `17 * * * *` with a random
sleep in front of it is the same idea as full jitter.

### What about a retry budget?

The previous lesson's budget is not a knob here, and that is deliberate. A
budget belongs to a single client that sends a lot of traffic, like
checkout-retry, where 10% of its traffic is a meaningful amount. These are 200
independent clients each sending one poll every four seconds. A per-client 10%
budget would almost never have a token to spend, and none of them can see what
the others are doing. For a fleet like this, the protection has to be in each
client's schedule: bounded attempts, growing delays, and jitter.

</details>
