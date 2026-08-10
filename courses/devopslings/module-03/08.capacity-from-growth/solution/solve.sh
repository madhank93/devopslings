#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# The volume holds one retention window, so the question is not "how much do we
# ingest" but "how much has the window ever held". Those differ here by 41%,
# because a month-end batch lands three days in thirty and a fiscal year-end
# close ran for a month and will run again.
#
# The peak window is computed by rolling a 90-day sum across every start date,
# not by summing the largest days — the volume is full when a *window* is large,
# and consecutive large days are what does it.
#
# Growth is applied to the peak rather than to the average, because the peak is
# not a fixed overhead on top of a growing baseline: the month-end batch is
# proportional to the month, so it grows with everything else.
#
# Headroom is 30% over the projection, and the reason is that the projection is
# a least-squares fit through a year of noisy data and the peak is a single
# observation of something seasonal. Both could be low. 30% is defensible;
# doubling it is buying insurance with somebody else's budget.
python3 - <<'PY' > /root/answers/capacity.md
import csv, re

HORIZON = 548

with open("/etc/ledger/retention.conf") as f:
    window = int(re.search(r"retention_days\s*=\s*(\d+)", f.read()).group(1))

with open("/srv/reports/ingest-daily.csv") as f:
    daily = [float(r["ingest_gb"]) for r in csv.DictReader(f)]

sums = [sum(daily[i:i + window]) for i in range(len(daily) - window + 1)]
peak = max(sums)

n = len(daily)
xs = range(n)
mx = sum(xs) / n
my = sum(daily) / n
slope = sum((x - mx) * (y - my) for x, y in zip(xs, daily)) / sum((x - mx) ** 2 for x in xs)
intercept = my - slope * mx
last = n - 1
ratio = (intercept + slope * (last + HORIZON)) / (intercept + slope * last)
projected = peak * ratio

print("basis=peak")
print("peak-window-gb=%.0f" % peak)
print("projected-window-gb=%.0f" % projected)
print("size-gb=%.0f" % (projected * 1.30))
PY
