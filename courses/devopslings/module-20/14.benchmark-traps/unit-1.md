---
title: "The same code, three different numbers"
---

## The situation

Every product page calls `catalog.price(sku)`. It is in the lesson's
`files/catalog.py`, and it is not yours to change. Three people benchmarked it
this week and got 1.4 million calls a second, 30,000, and "it moves around".
Nobody changed the code; they changed how they measured it.

The CI benchmark job runs `answers/bench.py` in the `checkout` container,
pinned to core 1, five times, each in a fresh process:

```
bash <lesson>/files/run.sh answers/bench.py
```

Each line is one run's number. Run it a few times and look at what moves.

## Three ways a benchmark lies

- **It times a cache.** `price()` keeps the last 2,048 answers. A loop that
  asks for one SKU 200,000 times does the real work once and then times a
  dictionary lookup. Production asks for 50,000 different products, and a
  third of its requests are for 500 bestsellers: `files/workload.py` holds a
  sample of 20,000 real lookups as `workload.KEYS`. Ask for those.
- **It times start-up.** A fresh process pays for things a running server paid
  for long ago: the first `price()` builds a rate table of 1.5 million
  entries, and every early lookup misses the cache. A server does that once,
  at boot, and serves for days. Warm up before you start the clock.
- **It times the neighbour.** Something else runs on core 1 in bursts: the
  search reindex job, `files/reindex.py`. A run that overlaps a burst gets
  part of the core, and reports a slower number for the same code. You cannot
  always stop the neighbour, but interference only ever **adds** time: of
  several timed passes, the fastest is the one it touched least.

## Your objectives

Rewrite `answers/bench.py` so that it prints, as its last line, the calls a
second production would see from a warm server, and prints about the same
number every time it runs.

## What you're being graded on

The check measures the code itself, warm, on `workload.KEYS`, with the same
neighbour running. Then it runs your benchmark five times. The median must be
within 80% to 125% of that measurement, the fastest and slowest of the five
within 20% of each other, and one more run with the neighbour paused must reach
80% of it too. Then it makes every price cost twice as much,
and your benchmark has to report the slower number too: a benchmark that does
not notice the code got slower is not measuring it.

<details>
<summary>Hint 1 — the number is far too high</summary>

Count how many different SKUs your loop asks for. If it is fewer than 2,048,
every call after the first pass is a cache hit. Import `KEYS` from `workload`
and loop over it.

</details>

<details>
<summary>Hint 2 — steady, but too low</summary>

Time a single pass over `KEYS` in a fresh process, then a second pass in the
same process. The first includes building the rate table and filling the
cache. Do one untimed pass first.

</details>

<details>
<summary>Hint 3 — the runs disagree</summary>

An average over all passes includes every burst the neighbour had. Time each
pass on its own and report the fastest.

</details>

<details>
<summary>Solution</summary>

`answers/bench.py`:

```python
import time

import catalog
from workload import KEYS

# Untimed pass: builds the rate table and fills the cache, as a server
# that has been up for a while already has.
for k in KEYS:
    catalog.price(k)

# The neighbour can only add time, so the fastest pass is the code's own speed.
best = float("inf")
for _ in range(15):
    start = time.perf_counter()
    for k in KEYS:
        catalog.price(k)
    best = min(best, time.perf_counter() - start)
print(round(len(KEYS) / best))
```

### In production

- Benchmark on a sample of real inputs, in their real order. A cache, a branch
  predictor and a CPU's own caches all reward repetition that production does
  not have.
- Report a minimum (or a low percentile) of many short passes for "how fast is
  this code", and keep the full distribution when the question is "how fast is
  this service": there the interference is part of the answer.
- A benchmark in CI is a test. Prove it fails: make the code slower on purpose
  and check the number moves.

</details>
