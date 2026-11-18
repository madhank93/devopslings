---
title: "A third of the CPU, in a line that never prints"
---

## The situation

The freight quoter prices an order in four steps: a base rate from the weight
band, surcharges for flags like `hazmat`, the best promotion the order
qualifies for, and rounding to the cent. It is CPU-bound, single-threaded per
request, and peak season needs about a quarter more quotes a second from the
same machines.

`apply_promotions` checks every promotion against every line of the order. It
looks slow, so it has been optimised twice, and the team's next plan is to
cache promotions per lane. Nobody has profiled it.

The code is `answers/quote.py` in `sandboxes/chaos-stack`. Profile it:

```
bash <lesson>/files/profile.sh answers/quote.py
```

## Reading a profile

`profile.sh` runs the quoter flat out for five seconds while a sampler looks
at its stack about every millisecond and writes down what it saw. Each sample
is a list of frames, outermost first: `bench.run;quote.quote;quote.apply_promotions`
means the code was inside `apply_promotions`, called from `quote`, called from
the benchmark's loop. A function that shows up in 30% of the samples is using
about 30% of the time.

The samples are written to `answers/quote.folded`, one line per distinct stack
with its count. That is the format a flame graph is drawn from: each frame is
a box as wide as its share of the samples, with the frames it called stacked
on top of it. `profile.sh` prints the same tree as text:

```
600 samples                                      total%  self%
bench.<module>                                   100.0    0.0
  bench.run                                       99.8    0.0
    quote.quote                                   99.8    0.4
      ...
```

- **total%** is the frame and everything it called: how much time you would
  save if this call cost nothing. The outermost frames are always near 100%.
- **self%** is the time the frame was the one actually running. A wide frame
  with a small self% is spending its time in its children; follow them down.

Read it top-down. Start at the frame that is the work you care about
(`quote.quote`), compare its children, and follow the widest until the reason
is obvious. The leaf with the biggest self% is often deep inside a library and
tells you *where* the CPU went, not *why*: the why is the frame in your own
code that called it.

To see it as a picture, paste `answers/quote.folded` into
[speedscope](https://www.speedscope.app) or run Brendan Gregg's
`flamegraph.pl` over it.

## Your objectives

1. Name the function that takes about a third of the CPU and that nobody
   suspected, in `answers/flame-graph.txt`:

   ```
   hot_function=<name>
   ```

2. Change `answers/quote.py` so it quotes at least 1.25 times as fast, with
   every price unchanged.

## What you're being graded on

The check reads `hot_function`, then runs your `quote.py` against the
original on the same 200 orders: the prices must match, and with
`LOG_LEVEL=DEBUG` the quoter must still log the order it is quoting. Then it
benchmarks the original and yours for three seconds each, back to back on the
same machine: yours must be at least 1.25 times as fast.

<details>
<summary>Hint 1 — where the time goes</summary>

`apply_promotions` is wide, and it is supposed to be: it is the pricing. Look
at the other wide child of `quote.quote`. What does it produce, and with the
logger at INFO, who ever sees it?

</details>

<details>
<summary>Hint 2 — the line that never prints</summary>

`log.debug(...)` checks the level and returns without logging. But Python
evaluates a call's arguments **before** making the call: the f-string, and the
`json.dumps` inside it, run every time, and then the result is thrown away.
Deleting the line makes it fast and leaves support blind the next time they
switch DEBUG on.

</details>

<details>
<summary>Solution</summary>

`answers/flame-graph.txt`:

```
hot_function=json.dumps
```

The profile shows `__init__.dumps` (that is `json/__init__.py`'s `dumps`)
under `quote.quote` with about a third of the samples, and the json encoder's
frames above it. It is called from the first line of `quote()`:

```python
log.debug(f"quoting order {json.dumps(order, indent=2, sort_keys=True)}")
```

The logger runs at INFO, so the message is never written, but the f-string is
built first, pretty-printing the whole order on every quote. Build it only
when it will be used:

```python
if log.isEnabledFor(logging.DEBUG):
    log.debug(f"quoting order {json.dumps(order, indent=2, sort_keys=True)}")
```

`log.debug("quoting order %s", order)` works too: the logger formats `%s`
only for a record it keeps. Either way the quoter runs about 50% faster, which
is more than another round on `apply_promotions` was ever going to find.

### Profiling in production

- A sampling profiler like the one here costs little because it only looks
  occasionally; that is why it can run on a live service. `py-spy`, `perf`,
  async-profiler and Go's pprof all sample, and all produce folded stacks.
- Profile under real load, not a single request: what is hot under load is
  what the load does, and a cache or a lock shows up differently at scale.
- Measure the fix the same way you found the problem: the same benchmark, the
  same machine, back to back. "It looks faster" is not a measurement.

</details>
