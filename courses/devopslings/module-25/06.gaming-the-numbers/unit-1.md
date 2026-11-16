---
title: "All four keys improved, and the team ships less"
---

## The situation

Six weeks into Q4, checkout's delivery dashboard is the best it has ever
been:

```
                                                Q3 (12 weeks)   Q4 so far (6 weeks)
deployment frequency, per week                       2.3             8.0      better
lead time for changes, median hours                 27.4            16.2      better
change failure rate                                 14.3%            2.1%     better
failed deployment recovery time, median minutes      140             110      better
```

Product is less happy. The features they were promised for October are late,
and the team says it is shipping as fast as ever.

The full dashboard, with how each number is computed, is in
`scratch/gaming-the-numbers/dashboard.txt`. The forge has eighteen weeks of
checkout's history: Q3, then Q4 so far.

## Your objectives

1. Find the number that was pushed, and the change that pushed it.
2. Measure what the dashboard should have shown, and propose a measure to put
   next to it that the same trick could not move.

Write them in `scratch/gaming-the-numbers/answer.txt`.

## What you're being graded on

The gamed metric must be the one that was actually moved. The count of
deployments that changed nothing must be exact. The honest lead times, for
each quarter, must be within 5% of the history's. The counter-signal must be a
measure of what was delivered, not of how often something was deployed.

<details>
<summary>Hint 1 — what changed at the start of Q4</summary>

```
git log --format='%ad %s' --date=short -- ops/
git tag -n9 'deploy/production/*' | grep trigger | sort | uniq -c
```

</details>

<details>
<summary>Hint 2 — what a deploy carried</summary>

Compare each production deploy's commit with the commit of the deploy before
it. If they are the same, the deploy delivered nothing.

</details>

<details>
<summary>Solution</summary>

```
gamed-metric=deployment frequency, raised by a nightly redeploy of the commit already in production
noop-deploys=41
lead-time-q3-hours=27.8
lead-time-q4-hours=53.4
counter-signal=changes delivered: commits reaching production per week, and lead time per change measured to the deploy that carried each commit
```

On Monday of week 13 one commit did two things: it moved the release train to
Thursdays only, and it added a nightly redeploy of whatever production was
already running, "to keep the CDN cache warm". 41 of Q4's 48 deployments are
that job. The other seven — six Thursday trains and a revert — are the only
ones that delivered anything, which is 1.2 a week against Q3's 2.3.

Every other number on the dashboard rode on it:

- **Change failure rate** divides by deployments. One failure over 48 looks
  like 2%; over the seven deployments that changed something it is 14%, the
  same as Q3.
- **Lead time** joined each commit to the *next deploy after it* by time. With
  a deploy every night, that is never more than a day away, whether or not it
  carries the commit. Measured to the deploy that actually carried each commit,
  lead time nearly doubled, because a once-a-week train makes everything wait
  for Thursday.
- **Recovery time** is one honest incident. One data point is not a trend.

### The part worth remembering

**The four keys are a guardrail, not a leaderboard.** They are designed to be
read together, because each one alone is cheap to move: deploy more often by
deploying nothing, cut failure rate by inflating the denominator, cut lead time
by measuring it against the wrong event. The moment one of them becomes a
target, somebody will find the cheap way to move it — usually without meaning
to game anything.

The defence is a counter-signal that measures the outcome directly. Here that
is **changes delivered**: commits reaching production per week, and lead time
measured per change to the deployment that carried it. A redeploy of an
unchanged commit cannot move either. More generally, pair every throughput
number with one that counts *what* was delivered, and every ratio with its raw
numerator and denominator.

</details>
