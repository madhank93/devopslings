---
title: "v2 is a third slower, and the diff is forty files"
---

## The situation

The catalogue's product-page renderer has a new release. On the benchmark,
v2 is a third slower than v1:

```
$ python3 /obs/catalog/bench.py /obs/catalog/v1
{"pages_per_cpu_s": 38170.0}
$ python3 /obs/catalog/bench.py /obs/catalog/v2
{"pages_per_cpu_s": 23390.0}
$ diff -rq -x __pycache__ /obs/catalog/v1 /obs/catalog/v2 | wc -l
40
```

Forty changed files: new markup, wording, a stock label, an SEO fix, a review
sort, thirty-three promo templates. Someone opened v1's flame graph and v2's
side by side, and they look alike: every frame a little different, nothing
obviously new. Reading forty diffs for a performance bug is a day. Bisecting
them is forty benchmarks.

Both versions are running, rendering pages and profiling themselves to
Pyroscope as `service_name="catalog"`, one tagged `version="v1"` and the other
`version="v2"`.

## A differential flame graph

Two flame graphs side by side ask your eyes to subtract. A **differential**
flame graph does the subtraction: it merges both profiles into one tree and
colours each frame by how its share of the samples changed between a
baseline and a comparison. Red grew, blue shrank, and the darker the colour,
the bigger the change. Shares, not raw sample counts: the two sides may have
run for different times or at different load, and the comparison is
"what fraction of the work is this frame".

In Pyroscope's UI (http://localhost:14040), choose **Diff View**. Put
`{service_name="catalog", version="v1"}` on the left (baseline) and
`{service_name="catalog", version="v2"}` on the right, with the same time
range on both. The table beside the graph lists each function's share on
both sides and the difference; sort by it.

A regression often is not a new frame at the top. It is an existing frame two
or three levels down that got wider, inside a parent that is wide anyway. In a
plain flame graph that reads as noise. In the diff it is the darkest red.

## Your objectives

1. Name the function the diff shows as the regression in
   `/obs/answers/regression.txt`:

   ```
   regression=<function>
   ```

2. Revert that one change in `/obs/catalog/v2` so v2 benchmarks within 5% of
   v1. The other changes stay.

## What you're being graded on

The check reads your answer, confirms that v1 is untouched and that v2 still
matches the release everywhere except the one file you reverted, then benchmarks v1 and v2 three times each, alternating,
two CPU-seconds a run. v2's median must be at least 95% of v1's.

<details>
<summary>Hint 1 — reading the diff</summary>

`render_page` and `format_listing` are red because something under them is.
Keep going down until you reach the frame that is red itself, not just
because of its children. Then `diff /obs/catalog/v1/<that file>
/obs/catalog/v2/<that file>`.

</details>

<details>
<summary>Hint 2 — noise versus signal</summary>

Several functions did change in v2 — `summarize_reviews`, `title_case`,
`meta_tags`, `stock_label` — and each moved a percent or two, some faster.
One moved by tens of percent.

</details>

<details>
<summary>Solution</summary>

The diff is red down one path, `render_page` → `format_listing` →
`format_price`, ending in a frame v1 does not have at all: `_symbol`.

```
regression=format_price
```

v1 built a dictionary of currency symbols once, at import, and looked each
price's symbol up in it. v2 replaced that with a function that scans the
currency list on every call:

```python
def _symbol(code):
    for c in CURRENCIES:
        if c["code"] == code:
            return c["symbol"]
```

Twenty-four prices a page, and a walk of up to forty entries for each.
Revert the one file:

```
cp /obs/catalog/v1/money.py /obs/catalog/v2/money.py
```

### Differential profiles in practice

- Compare like with like: the same traffic mix and the same time of day on
  both sides, or the diff shows the traffic change instead of the code
  change. A canary and its baseline, profiled side by side, are the ideal
  pair.
- Tag profiles with the version, so the comparison is a label filter, not a
  hunt for the right time window.
- The diff points at the frame; `git log -p` on that file finds the change.
  That is one diff to read, not forty.

</details>
