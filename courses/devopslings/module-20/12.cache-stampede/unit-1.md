---
title: "One expiry takes the database down"
---

## The situation

The catalog API serves 20 products to shoppers, about 300 requests a second.
Behind it, `catalog-db` answers a product query in about 150ms when it is
quiet, gets 10ms slower for every query running beside it, and has 30
connections: the 31st query at once is refused.

Nobody would put 300 queries a second on that, so the API caches each product
for 15 seconds, the longest a price may be stale. The cache is
`answers/cache.py`:

```python
def get(key, load):
    hit = _store.get(key)
    if hit and hit[1] > time.monotonic():
        return hit[0]
    value = load(key)
    _store[key] = (value, time.monotonic() + TTL)
    return value
```

The hit ratio is over 99%. And twice a minute, catalog-db refuses
connections and some shoppers get errors. Replay it:

```
docker compose exec -T k6 k6 run - < answers/browse.js
```

then read catalog-db's counters (the command is in the init output).

## The stampede

After a deploy every product is loaded at about the same moment, so every
product expires at about the same moment 15 seconds later. For the 150ms it
takes to reload one, every request for that product misses: at 15 requests a
second per product, two or three of them, each making its own query. Twenty
products at once is dozens of queries, and each one slows catalog-db, which
makes the reload take longer, which lets more requests miss. That is a cache
stampede, also called a thundering herd or dog-piling.

The cache's hit ratio says nothing about it. The damage is concentrated in
the moment of expiry, which is too short to move an average.

## Your objectives

Change `answers/cache.py` so that when products expire, catalog-db is not
overwhelmed: no refused queries and every shopper served. Prices must stay at
most 15 seconds old. Apply it with `bash <lesson>/files/deploy.sh`.

## What you're being graded on

The check deploys your cache, loads every product at the same moment, and runs
the lesson's copy of `browse.js` for 35 seconds, which spans two expiries.
Every request must be served, catalog-db must refuse nothing, no price may be
more than 15 seconds old, and the p99 must stay under a second.

<details>
<summary>Hint 1 — a longer TTL</summary>

A TTL of five minutes makes the stampede happen every five minutes instead of
every 15 seconds. It is just as large when it comes, and shoppers see prices
five minutes old in between. Fix what happens at expiry, not how often it
happens.

</details>

<details>
<summary>Hint 2 — two ways out</summary>

- **Single-flight**: when a product is being reloaded, the other requests for
  it wait for that load and share its result, instead of starting their own.
  One query per product per expiry.
- **Jitter**: give each entry a slightly different lifetime, so products
  expire spread out over a few seconds instead of together.

Either one works here. Single-flight needs a lock per key: one lock for the
whole cache makes every request wait for every reload.

</details>

<details>
<summary>Solution</summary>

```python
import threading
import time
from collections import defaultdict

TTL = 15.0
_store = {}
_loading = defaultdict(threading.Lock)  # one lock per key


def get(key, load):
    hit = _store.get(key)
    if hit and hit[1] > time.monotonic():
        return hit[0]
    with _loading[key]:
        # Whoever held the lock before us may have just loaded it.
        hit = _store.get(key)
        if hit and hit[1] > time.monotonic():
            return hit[0]
        value = load(key)
        _store[key] = (value, time.monotonic() + TTL)
        return value
```

The second look inside the lock is what makes it single-flight: the requests
that queued behind the first reload find a fresh entry when they get the lock
and never call catalog-db. Each expiry now costs 20 queries, and catalog-db's
peak stays well under its 30 connections.

### Jitter

```python
_store[key] = (value, time.monotonic() + TTL * random.uniform(0.8, 1.0))
```

Expiries spread over three seconds, so only a product or two reloads at a
time. Jitter downward from the limit, never above it: `TTL * 1.2` breaks the
staleness promise. Jitter does not help a cold start, when nothing is cached
yet; single-flight does.

### Other defences

- **Serve stale while revalidating**: keep returning the expired value while
  one background request refreshes it. Nobody waits, at the cost of serving a
  value a little past its TTL.
- **Refresh ahead**: reload an entry shortly before it expires, while it is
  still being served.
- **Across many API instances**, a lock in one process does not stop the
  others. Single-flight then needs a shared lock (a Redis `SET NX` with a
  short expiry) or request coalescing at a proxy in front of the database.

</details>
