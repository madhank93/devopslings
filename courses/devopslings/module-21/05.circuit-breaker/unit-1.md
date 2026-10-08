---
title: "Circuit breaker: failing fast beats failing slowly"
---

## The situation

`checkout` already does what the earlier lessons asked: it calls `pricing` with
a timeout of `(1, 2)` and, when the call fails, answers with a fallback price.
A slow `pricing` can no longer take it down.

Watch what it does when `pricing` is slow anyway. Every request still goes to
`pricing`, waits two seconds, gives up, and serves the fallback. The tenth
customer pays the same two seconds as the first, to learn what `checkout`
already knew nine requests ago — and `pricing`, already struggling, gets every
one of those requests piled on top.

A circuit breaker remembers. After enough failures in a row it **opens**: calls
stop going out at all and the fallback is served immediately. After a cooldown
it goes **half-open** and lets a single trial request through. If the trial
succeeds, it **closes** and normal service resumes; if it fails, it opens again
for another cooldown.

## Your objectives

Implement `Breaker` in `scratch/circuit-breaker/breaker.py` (from the repository
root) to this spec:

1. **Closed** — every call goes through. **5 consecutive failures** open it. A
   success resets the count.
2. **Open** — no call goes through for **5 seconds**.
3. **Half-open** — exactly **one** trial call goes through; everyone else keeps
   getting the fallback while it is in flight. Success closes the breaker;
   failure opens it for another 5 seconds.

The harness calls your methods like this:

```python
with lock:
    allowed = cb.allow()        # False -> answer from the fallback, don't call
if allowed:
    ... call pricing with timeout=TIMEOUT ...
    with lock:
        cb.success()  # or cb.failure()
```

The lock means you don't need your own. The pricing call runs *outside* it, so
while one request is waiting on `pricing`, others are calling `allow()` — that
is what makes "exactly one trial" something you have to keep track of.

## Trying it

`scratch/circuit-breaker/try` deploys your `breaker.py` into the `checkout`
container (port 8081, beside the real `checkout`), restarts it with a fresh
breaker, and sends requests:

```
$ scratch/circuit-breaker/try 3
#1   200 pricing  called      6ms
#2   200 pricing  called      4ms
#3   200 pricing  called      4ms
```

`try N GAP` sends N requests GAP seconds apart; `try burst N` sends N at once.
Make `pricing` fail fast or slow, and restore it, through toxiproxy:

```
curl -s -X POST localhost:8474/proxies/pricing -d '{"enabled":false}'   # refuses connections
curl -s -X POST localhost:8474/proxies/pricing/toxics -H 'Content-Type: application/json' \
  -d '{"name":"latency","type":"latency","stream":"downstream","attributes":{"latency":8000}}'
curl -s -X POST localhost:8474/reset                                     # healthy again
```

## What you're being graded on

Every transition, observed:

- **Opens under sustained failure.** A k6 run of 10 users for 15 seconds with
  `pricing` 8s slow. Thresholds: at most 15 calls reach `pricing`, p(95) under
  500ms, every request answered with a price.
- **Half-opens and closes on recovery.** The fault is lifted; within the
  cooldown a trial reaches `pricing`, and afterwards 10 simultaneous requests
  all get the real price.
- **Opens at the right point.** One request at a time against a `pricing` that
  refuses connections: 3 failures and a success must not open it, 5 failures in
  a row must.
- **Doesn't open on a healthy dependency.** With `pricing` 300ms slow but
  working, every request gets the real price.

<details>
<summary>Hint 1 — the obvious fix is a shorter timeout</summary>

If the problem is that every request waits two seconds, why not make the
timeout 100ms?

Because each request still goes to `pricing`. You have made the failure
cheaper, not stopped paying it, and the load on the struggling dependency is
the same — higher, in fact, because each user now retries every 100ms instead
of every two seconds. And the day `pricing` is merely slow, at 300ms, every
call fails that would have succeeded.

The timeout bounds one call. The breaker decides whether to make it.

</details>

<details>
<summary>Hint 2 — three states, and the one people skip</summary>

Track a state (`closed`, `open`, `half-open`), a consecutive-failure count, and
when the breaker opened. `allow()` is where the time-based transition happens:
an open breaker whose cooldown has passed becomes half-open.

The common bug is half-open that lets everyone through. With 10 users, the
moment the cooldown ends ten requests call `allow()` within a few
milliseconds; if all ten are admitted, the "trial" is a full wave of traffic
against a dependency that may still be down. Remember that a trial is in
flight, and refuse everyone else until it comes back.

</details>

<details>
<summary>Solution</summary>

`scratch/circuit-breaker/breaker.py`:

```python
import time

TIMEOUT = (1.0, 2.0)


class Breaker:
    THRESHOLD = 5
    COOLDOWN = 5.0

    def __init__(self):
        self.state = "closed"
        self.failures = 0
        self.opened_at = 0.0
        self.trial_in_flight = False

    def allow(self):
        if self.state == "closed":
            return True
        if self.state == "open":
            if time.monotonic() - self.opened_at < self.COOLDOWN:
                return False
            self.state = "half-open"
            self.trial_in_flight = False
        if self.trial_in_flight:
            return False
        self.trial_in_flight = True
        return True

    def success(self):
        self.state = "closed"
        self.failures = 0
        self.trial_in_flight = False

    def failure(self):
        self.failures += 1
        self.trial_in_flight = False
        if self.state == "half-open" or self.failures >= self.THRESHOLD:
            self.state = "open"
            self.opened_at = time.monotonic()
```

Under the 8s fault, the starter sends roughly 70 calls to `pricing` in 15
seconds, each one costing its customer two seconds. The breaker sends about
12: the first wave of 10, which is how it finds out, and one trial per
cooldown. Everything else is answered in a millisecond.

### Why it is worth the state

**Failing fast protects the caller.** A request answered by an open breaker
costs nothing, so `checkout`'s threads are free and its latency is flat. The
timeout alone kept `checkout` *alive*; the breaker keeps it *fast*.

**Failing fast protects the dependency.** A service that is slow because it is
overloaded recovers sooner when its callers stop sending it work. Without a
breaker, every caller keeps the pressure on exactly when it hurts most —
which is how a dependency that would have recovered in a minute stays down for
an hour.

**Half-open is how it ends.** A breaker that opens and never tries again turns
a ten-second blip into an outage only a restart fixes. One trial at a time is
the cheapest possible question — "are you back?" — and the answer reopens or
closes it.

### Choosing the numbers

The threshold trades false alarms against wasted calls: too low and one
dropped packet opens it, too high and the first wave of a real outage is
expensive. Counting *consecutive* failures, or a failure rate over a window
(what libraries like resilience4j do), keeps sporadic errors on a healthy
service from adding up.

The cooldown is roughly "how long does this dependency take to recover". Too
short and you probe a dead service constantly; too long and you serve the
fallback after it is back.

### What this does not cover

This breaker is per process. With 50 `checkout` replicas there are 50
breakers, each discovering the fault for itself and each sending its own trial.
That is usually fine — the point is bounding the waste, not eliminating it —
and it is why shared breakers in a service mesh exist when it is not.

</details>
