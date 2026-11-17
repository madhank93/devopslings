---
title: "SLO and error budget"
---

## The situation

The indicator from the last lesson is now an objective: **99.5% of valid
customer requests are good, measured over 30 days.** The other 0.5% is the
error budget, the failures the shop has agreed it can afford.

`/ha/sre/requests-30d.csv` has the last 30 days, one row per minute:

```
minute,valid,good
2026-10-14T00:00,9,9
2026-10-14T00:01,7,7
...
```

In the early hours of 26 October the shop had an outage that lasted about an
hour and a half. The incident channel's first message was "we've burned 40%
of our error budget overnight". Was that right?

## Your objectives

Fill in `/ha/answers/budget.txt`:

1. How many valid requests the 30 days had, how many the budget allows to
   fail, and how many did.
2. What share of the budget is left.
3. What share of the budget the night outage spent, and its burn rate while
   it lasted.

## What you're being graded on

Every number is recomputed from the same data. Counts must be exact; the
percentages and the burn rate within 10%.

## Try it yourself

```
awk -F, 'NR > 1 { v += $2; g += $3 } END { print v, g }' /ha/sre/requests-30d.csv
grep '^2026-10-26T0[2-5]' /ha/sre/requests-30d.csv | awk -F, '$3 < $2'
```

<details>
<summary>Hint 1 — the budget is in requests</summary>

0.5% of 30 days is 216 minutes. That only equals 0.5% of the requests if
every minute is as busy as every other, and the shop gets fifteen times more
traffic at lunchtime than at three in the morning. The SLO counts requests,
so the budget does too.

</details>

<details>
<summary>Hint 2 — finding the outage</summary>

A handful of requests fail every hour; that is the background, and it is
inside the budget on purpose. The outage is where the failures stop being a
handful: look for the run of minutes where a large share of requests failed.

</details>

<details>
<summary>Hint 3 — burn rate</summary>

Burn rate is how fast the budget is being spent relative to spending it
exactly evenly over the window. An error rate equal to the allowed 0.5% is a
burn rate of 1: the budget lasts exactly 30 days. An error rate of 5% is a
burn rate of 10.

</details>

<details>
<summary>Solution</summary>

```bash
csv=/ha/sre/requests-30d.csv
awk -F, 'NR > 1 { v += $2; g += $3 } END { print v, v * 0.005, v - g }' "$csv"
# the outage: minutes before 06:00 on the 26th where two or more requests failed
awk -F, '$1 ~ /^2026-10-26T0[0-5]/ && $2 - $3 >= 2' "$csv" | sed -n '1p;$p'
# then, between those two minutes:
awk -F, '$1 >= "2026-10-26T03:12" && $1 <= "2026-10-26T04:40" { v += $2; b += $2 - $3 }
  END { print b, b / v, (b / v) / 0.005 }' "$csv"
```

With a budget of roughly 9,700 requests, the outage failed a few hundred: a
few percent of the budget, not 40%. Its burn rate was high, around 80, and
that is the number an alert cares about.

### Two different questions

The burn rate says how bad it was while it lasted. The budget share says
what it cost. A night outage scores high on the first and low on the
second, because few people were there to be failed. The next lesson pages on
burn rate, because that is what tells you to act now. The policy lesson acts
on the budget share, because that is what tells you whether to keep
shipping.

### Why not minutes

A time-based budget ("216 minutes of downtime a month") is easier to say and
easier to measure, which is why it is common. It is also wrong in both
directions here: it overstates a night outage that few customers saw, and it
understates twenty minutes of half-failing checkout at lunch, which cost
several times more requests than the night outage did.

</details>
