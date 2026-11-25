---
title: "300 ms in one span, and nothing underneath it"
---

## The situation

`quoter` prices insurance quotes, one a second, and each quote is a trace in
Tempo. Every trace looks the same:

```
price-quote  ████████████████████████████████████  296 ms
```

One span, 300 ms, no children. The budget for a quote is 100 ms. Module 19's
`exemplars` went from a slow metric to the trace behind it; here the trace is
already in hand, and it has run out of detail. The proposal is to add spans
around every step until one of them is slow. That stops working at the
function boundary: wrap `rider_premium` in a span and you learn it is slow,
twelve times a quote, and nothing about why.

`quoter` also profiles itself continuously to Pyroscope. A profile has every
function and every line, but no idea which request it belonged to. The
missing piece is the link.

## Span profiles

The Pyroscope SDK can label every sample it takes with the ID of the span
that was running at the time. In Python that is one span processor,
`pyroscope.otel.PyroscopeSpanProcessor`, added to the `TracerProvider`. It
does two things for each root span:

- it labels the profiler's samples taken while the span runs with the span's
  ID, so Pyroscope can return the profile of *that span only*;
- it sets a `pyroscope.profile.id` attribute on the span, which tells Grafana
  there is a profile to link to.

Grafana's Tempo data source is set up to follow that link: open a trace in
**Explore → Tempo**, select the `price-quote` span, and **Profiles for this
span** opens the flame graph of the samples taken during it. The flame graph
reads like any other: the span's work, function by function, down to the
loop.

`quoter` runs under a supervisor and restarts when `/obs/quoter/quoter.py`
is saved.

## Your objectives

1. Link `quoter`'s spans to its profiles, and name the function the profile
   of a slow `price-quote` span spends its time in, in
   `/obs/answers/span.txt`:

   ```
   function=<name>
   ```

2. Change `/obs/quoter/quoter.py` so `price-quote` comes in under 100 ms.

## What you're being graded on

The check reads your answer and prices a few sample quotes with your
`quoter.py` and with the original: the prices must match. Then it queries
Tempo for the `price-quote` spans since `quoter` last restarted: every one
must carry `pyroscope.profile.id` and still price twelve riders, and their
90th percentile must be under 100 ms.

<details>
<summary>Hint 1 — making the link</summary>

```python
from pyroscope.otel import PyroscopeSpanProcessor
...
provider.add_span_processor(PyroscopeSpanProcessor())
```

Add it before the exporter's processor. Save, wait for a new trace, and the
span now has a `pyroscope.profile.id` attribute and the profiles link.

</details>

<details>
<summary>Hint 2 — reading the span's profile</summary>

Under `price_quote`, nearly all the width is `rider_premium`, and under it
one function. What does that function compute, and does any of it depend on
the quote?

</details>

<details>
<summary>Solution</summary>

```
function=mortality_table
```

The span's profile is almost entirely `rider_premium` → `mortality_table`.
`mortality_table` integrates a survival curve for every age from 0 to 119.
It depends on nothing in the quote, and it is rebuilt for every rider of every
quote: twelve times per span. Build it once:

```python
MORTALITY = mortality_table()

def rider_premium(rider, age):
    return 30.0 * RIDERS[rider] * (1 - MORTALITY[age])
```

`price-quote` drops to a few milliseconds.

### Traces and profiles together

- A trace tells you *which* request was slow and which service and span the
  time was in. A profile tells you *which code* the CPU was running. Neither
  answers both, and span profiles join them on the span ID.
- Span profiles cover CPU time on the instrumented process. A span that is
  slow because it waits — on a lock, a socket, a database — shows little CPU;
  the off-CPU lesson in this module is the tool for that.
- The Python SDK labels root spans. In a service where the slow span is deep
  in the trace, the root span's profile still contains it; read down from the
  matching function.

</details>
