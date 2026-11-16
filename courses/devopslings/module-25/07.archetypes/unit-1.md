---
title: "Where does this team actually sit?"
---

## The situation

A second team runs checkout in another region. They ship once a week, on a
Wednesday release train, and they have done so for as long as anybody can
remember. Their manager has a slide that calls them "Low performers, by the
old chart" and a budget request to fix that.

The old chart is gone. DORA's 2025 report replaced the Elite/High/Medium/Low
tiers with seven team archetypes, because the tiers measured speed and called
it performance: a team that ships weekly and never breaks anything landed in
the same bucket as one that ships weekly and breaks everything.

The forge now holds this team's twelve weeks. The platform team's reading of
the seven archetypes, with the bands they use, is in
`scratch/archetypes/profiles.md`; the team's latest survey is in
`team-survey.txt` next to it.

## Your objectives

1. Measure the team's throughput and instability from its history:
   deployments per week, median lead time for changes, rework rate.
2. Place the team in one of the seven archetypes, using those numbers and the
   survey.

Write them in `scratch/archetypes/answer.txt`.

## What you're being graded on

Each number must match the history: deployments per week within 0.15, the
median lead time within 5%, the rework rate within half a percentage point.
Then the archetype must be the one the numbers and the survey support.

<details>
<summary>Hint 1 — reuse what you built</summary>

Every number here is one you have already computed for the other team:
count-your-deploys, lead-time and rework-rate. The definitions do not change
because the team is slower.

</details>

<details>
<summary>Hint 2 — read across the row</summary>

Throughput narrows it to the low-throughput archetypes. Instability splits
those in two. The survey decides between what is left.

</details>

<details>
<summary>Solution</summary>

```
deploys-per-week=1.08
lead-time-median-hours=53.3
rework-rate=7.7
archetype=Stable and methodical
```

Thirteen production deployments in twelve weeks, and a median change waits a
little over two days for the train: low throughput. One deployment in
thirteen was rework, a revert of the PDF invoices feature the afternoon it
shipped: low instability. Friction and burnout are low, and the team rates its
product highly.

Low throughput and low instability leave two archetypes, and the survey
splits them. *Constrained by process* is the same delivery shape in a team that
is fighting its own process, with friction and burnout high. This team is not.
It is *Stable and methodical*: it delivers on purpose at a deliberate pace, and
what it delivers works.

### The part worth remembering

**An archetype is a reading of several signals together, and the delivery
numbers are only some of them.** The old tiers ranked teams on the four keys
alone, so they could only ever say "faster". The archetypes ask what the speed
is costing and what it is buying: whether production stays healthy, whether
the team is burning out, whether the product is any good.

That changes what the manager's budget request should be. A *Stable and
methodical* team that wants to move faster has something to protect while it
does: its low instability and its people. Speed it up by shrinking the batch —
a second train, smaller changes — and watch rework and burnout as it goes,
rather than by being told it is Low.

</details>
