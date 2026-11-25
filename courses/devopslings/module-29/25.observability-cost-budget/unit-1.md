---
title: "The observability bill is three times the budget"
---

## The situation

The fleet's traces, logs and metrics cost $31,200 a month. Finance has set
the budget at $10,000, starting next month. Three documents in `/obs/cost/`:

- `USAGE.md`: what each signal sends today, and what it is made of
- `PRICES.md`: the vendor's price list, with today's bill worked through
- `REQUIREMENTS.md`: four things the teams must still be able to do

The easy plans are wrong in instructive ways. Cutting every signal by
two thirds breaks incident reviews. Sampling traces at 1% leaves the error
the customer called about unrecorded. Dropping retention to a week makes
the SLO meaningless.

## The knobs

Each signal has a volume knob and a time knob, and the price list charges
for both:

- **Traces**: the tail-sampling rate for traces *without* an error (traces
  with one are always kept), and retention. A sampled-out trace is gone for
  good; the metrics derived from spans before sampling still count it.
- **Logs**: dropping whole levels at ingest, and retention. Look at what
  each level is made of before deciding.
- **Metrics**: an active-series limit, and retention. The series count is
  set by label cardinality, and one label is most of it.

Every cut stops some question from being answerable. Say which, in the plan,
so nobody finds out in the middle of an incident.

## Your objectives

Fill in `/obs/answers/plan.yaml`: the knobs for each signal, the monthly
cost of each worked out from `PRICES.md`, the total, and for each signal
what your cuts stop you answering.

## What you're being graded on

- nothing in `REQUIREMENTS.md` is broken
- each signal's `cost` matches the price list applied to your knobs, within
  2%, and `total` is their sum
- the total is at or under $10,000
- for every cut you made, `loses` says what it costs you: which requests
  lose their trace, what only debug logs recorded, what the per-user series
  answered, how far back each signal no longer goes

<details>
<summary>Hint 1 — where the money is</summary>

Work out what each knob is worth on its own. Traces at 100% are half the
bill, and most spans are in traces nothing went wrong in. More than half the
log volume is one level. Most metric series come from one label.

</details>

<details>
<summary>Hint 2 — the traces formula</summary>

Spans kept = 6,000M x (2% + 98% x sample_percent). Then multiply by
(1.00 + 0.05 x retention_days).

</details>

<details>
<summary>Solution</summary>

One plan that fits, with room to spare:

```
traces   10% of non-error traces, 14 days
         6,000 x (0.02 + 0.98 x 0.10) = 708M spans x (1.00 + 0.05 x 14)  = $1,204
logs     drop debug, 30 days
         30,000 GB x 45% = 13,500 GB x (0.15 + 0.005 x 30)               = $4,050
metrics  1,200,000 series (no user_id label), 35 days
         1,200,000 x (0.0006 + 0.00002 x 35)                              = $1,560
                                                                   total   $6,814
```

And what each cut costs:

- **traces**: nine in ten successful requests have no trace; latency for
  them comes from span metrics, and a specific slow-but-successful request
  may not be findable. Nothing older than two weeks.
- **logs**: debug was the only record of a request's internal decisions;
  reproducing a bug now means turning debug on for that service afterwards.
- **metrics**: "how slow is it for this one user" stops being a query, and
  trends older than five weeks are gone.

The spare $3,000 is a decision too: more trace sampling, or longer metric
retention for capacity planning, whichever question the teams ask more.

### The ways this goes wrong

- **Error traces under two weeks.** Cheap, and the incident review finds
  nothing.
- **Dropping warn or error logs.** Security needs them for 30 days.
- **Metrics under 28 days.** An SLO over a window you cannot see.
- **A series limit under 1.2M.** The limit drops series at random,
  including ones an alert depends on. Remove the label instead.
- **A limit between 1.2M and 3M.** With `user_id` still on, the fleet
  emits 3M series, and the limit drops the excess at random, the same way.
- **"We lose some visibility."** That is not a question anyone can check
  against. Name the question.

</details>
