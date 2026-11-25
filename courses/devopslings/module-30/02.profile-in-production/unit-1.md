---
title: "five times the CPU in production as in the load test"
---

## The situation

The pricing API uses about half a CPU in production, at 8000 orders a second.
The pre-release load test sends the same 8000 orders a second to the same
build and uses a fifth of that:

```
$ python3 /obs/pricing/loadtest.py
80000 orders in 10.0 s, 10% of a CPU
```

Two engineers have spent a day trying to reproduce the production load
locally: more orders, more concurrency, a bigger box. The load test stays
cool. Module 20's `flame-graph` profiled a program you were allowed to run
flat out on your own machine. This one only misbehaves in production, and
production is where you cannot attach a debugger.

You do not need to. The service has been sending a **continuous profile** to
Pyroscope since it was deployed: a low-rate sampling profiler runs inside the
process all the time and ships what it sees every ten seconds.

## Reading a continuous profile

Open Grafana at http://localhost:13000, **Explore**, pick the **Pyroscope**
data source, profile type `process_cpu` → `cpu`, and the label
`service_name="pricing"`. (Pyroscope's own UI at http://localhost:14040 shows
the same data.) The flame graph is every sample in the selected time range
merged together, outermost frame at the top in Grafana's layout:

- A frame's **width** is the share of samples that had it on the stack:
  itself and everything it called. `price_order` is near 100% because every
  request goes through it.
- **Self** is time in the frame itself. The table beside the graph sorts by
  either.
- Read top-down from the frame that is the work you care about, and compare
  its children.

The time range is a choice. A continuous profile keeps history, so you can
compare yesterday with today, or the five minutes around a spike with the
hour before it.

Then ask the second question: why is that function hot *here* and not in the
load test? The profile names the code; the inputs production sends it are in
`/obs/pricing/orders.py`.

## Your objectives

1. Name the function that takes most of production's CPU in
   `/obs/answers/profile.txt`:

   ```
   hot_function=<name>
   ```

2. Change `/obs/pricing/pricing.py` so the same production traffic costs at
   least 40% less CPU, with every price unchanged. The running service
   reloads when you save.

## What you're being graded on

The check reads `hot_function`, then replays a fixed sample of production
traffic (`/obs/pricing/replay.py`) through the original `pricing.py` and
through yours, twice each: the results must be identical, and your best run
must use at most 60% of the CPU seconds of the original's best run.

<details>
<summary>Hint 1 — the two profiles</summary>

Profile the load test yourself (`python3 -m cProfile -s cumtime
/obs/pricing/loadtest.py | head -25`) and compare it with Pyroscope's. Under
the load test, `normalize_lines` is a sliver. In production it is almost all
of it. What does production send that the load test does not? Read
`make_order` in `orders.py`.

</details>

<details>
<summary>Hint 2 — the shape of the cost</summary>

For each line, `normalize_lines` walks every line merged so far. That is
nothing for an order of 5 lines and 4 million comparisons for one of 2000.
Look the SKU up instead of searching for it.

</details>

<details>
<summary>Solution</summary>

```
hot_function=normalize_lines
```

In production, about nine tenths of the profile is `normalize_lines` under
`price_order`. acme's procurement system sends whole-catalogue reorders of
1500 to 2500 lines, and `normalize_lines` is quadratic in the line count. The
load test sends web orders of 2 to 8 lines, where it costs nothing, so no
amount of load-test traffic reproduces it.

A dict keyed by SKU makes it linear, and Python dicts keep insertion order,
so the merged lines come out in the same order as before:

```python
def normalize_lines(lines):
    """Merge lines that repeat a SKU, keeping first-seen order."""
    merged = {}
    for line in lines:
        m = merged.get(line["sku"])
        if m:
            m["qty"] += line["qty"]
        else:
            merged[line["sku"]] = {"sku": line["sku"], "qty": line["qty"], "unit": line["unit"]}
    return list(merged.values())
```

### Continuous profiling

- The profile answers "what is the CPU doing", not "which input made it do
  that". Here the input was found by asking why the hot function would be hot
  only in production. Tags help: a profiler tagged with tenant or endpoint
  lets you split the flame graph by them directly.
- A load test proves the cases it sends. Feed it a sample of real traffic
  shapes, including the largest customers, and the next regression of this
  kind shows up before release.
- Sampling at 100 Hz costs little; the profiler-overhead lesson later in
  this module measures how little, and what happens at 1000 Hz.

</details>
