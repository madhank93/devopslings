---
title: "size the volume for eighteen months, from a year of what actually happened"
---

## The situation

Finance is buying the ledger archive volume for the next eighteen months and
wants a number today. You have a year of daily ingest and a retention policy.

```
$ head -3 /srv/reports/ingest-daily.csv
date,ingest_gb
2025-08-10,2.083
2025-08-11,1.902

$ cat /etc/ledger/retention.conf
retention_days = 90
```

Records older than ninety days are deleted nightly, so in the steady state the
volume holds one ninety-day window of ingest. The question is which window.

## Your objectives

`/root/answers/capacity.md`, one key per line:

| key | answer |
|---|---|
| `basis` | one of `mean`, `trailing`, `peak`, `median` |
| `peak-window-gb` | the largest amount the retention window has ever held |
| `projected-window-gb` | that window eighteen months on, with growth applied |
| `size-gb` | what to buy |

Ingest has grown linearly and is expected to continue. Assume the shape of the
peaks stays as it is while the level rises, and size for 548 days after the last
date in the file.

## What you're being graded on

`peak-window-gb` within 3% of the true rolling maximum, `projected-window-gb`
within 12% of the fitted projection — the tolerance is there because fitting the
daily series and fitting monthly totals give slightly different slopes, and both
are defensible — and `size-gb` between 1.1x and 1.85x the projection. The grader
recomputes all of it from the same two files you read.

<details>
<summary>Hint 1 — the volume holds a window, not a day</summary>

The average daily ingest is about 4.4 GB, and 90 × 4.4 is 396 GB. That is the
number most people write down, and it is the size at which the volume is full
exactly half the time.

The volume does not fill up on an average day. It fills up during whichever
ninety consecutive days were the heaviest, so that is the window to measure:

```
$ python3 - <<'PY'
import csv
daily = [float(r["ingest_gb"]) for r in csv.DictReader(open("/srv/reports/ingest-daily.csv"))]
sums = [sum(daily[i:i+90]) for i in range(len(daily)-89)]
print("mean-based  %.0f" % (sum(daily)/len(daily)*90))
print("trailing    %.0f" % sums[-1])
print("peak        %.0f  (starting day %d)" % (max(sums), sums.index(max(sums))))
PY
mean-based  396
trailing    470
peak        560  (starting day 195)
```

Three defensible-sounding numbers, 41% apart end to end. Note that the peak is
not the most recent window — sizing from current usage misses it entirely.

</details>

<details>
<summary>Hint 2 — what is in that peak, and whether it comes back</summary>

Plot the daily series, or just look at it, and there are three separate things
happening:

- a steady linear climb, about 8 MB/day/day
- a month-end batch, three days in every thirty at roughly 2.5x
- a month-long stretch around day 195 at roughly 2.2x — the fiscal year-end
  close

The peak window is the one containing the year-end close. The question a
capacity number has to answer is whether that recurs, and a fiscal year-end
does, every year, inside any eighteen-month horizon. It is not an outlier to be
trimmed. It is the load.

This is the difference between sizing for the variance and sizing for the mean.
The mean is a description of the past. The peak is a prediction about the
future, and it is the one the volume experiences.

</details>

<details>
<summary>Hint 3 — growth applies to the peak too</summary>

A common half-answer projects the *average* forward and adds the peak on top as
a fixed overhead. That underestimates, because the peak is not a fixed
overhead — the month-end batch is proportional to the month, and the year-end
close is proportional to the year. When the baseline doubles, so does the spike.

So fit the series, take the ratio of fitted ingest at day 912 to day 364, and
scale the peak window by it:

```
ratio     1.92
projected 560 × 1.92 = 1074 GB
```

</details>

<details>
<summary>Solution</summary>

```
basis=peak
peak-window-gb=560
projected-window-gb=1074
size-gb=1396
```

Roughly 1.4 TB, with 30% headroom over the projection.

The headroom is the part worth being able to defend out loud, because it is the
part that is spending money. Two reasons for it here: the projection is a
least-squares fit through a year of noisy data, and the peak is a *single*
observation of a seasonal event — next year's close could be heavier for reasons
that have nothing to do with the trend. Both estimates can be low at the same
time.

That argument also bounds it from the other side. 30% is insurance against known
uncertainty; 200% is buying three times the disk on a hunch, with somebody's
budget, and the grader rejects that too. "How much headroom" is a question with
a defensible answer, not a shrug.

What generalises from this one: the number a capacity question wants is almost
never an average. Find the unit the resource actually holds — here, a retention
window rather than a day — take the worst one that has happened, decide whether
it recurs, grow it, and then add headroom you can justify in a sentence.

</details>
