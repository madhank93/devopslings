---
kind: lesson
title: "size the volume for eighteen months, from a year of what actually happened"
description: |
  A year of daily ingest, a retention policy, and a purchase order that has to
  be right. The average tells you what the volume holds on a normal day, and
  the volume does not fail on a normal day.
name: capacity-from-growth
slug: capacity-from-growth
createdAt: "2026-08-10"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 240
    run: |
      install -d /srv/reports /etc/ledger /root/answers

      cat > /usr/local/bin/seed-ingest <<'PY'
      #!/usr/bin/env python3
      # A year of daily ingest for the ledger archive. Three things are going on
      # in this series, and only one of them is visible in the average: a steady
      # linear climb, a month-end batch that lands three days out of thirty, and
      # a fiscal year-end close that ran for a month and will run again.
      import datetime
      import random

      rnd = random.Random(20260810)
      end = datetime.date(2026, 8, 9)
      start = end - datetime.timedelta(days=364)

      rows = []
      for t in range(365):
          daily = 2.0 + 0.008 * t
          if t % 30 >= 27:
              daily *= 2.5
          if 195 <= t < 225:
              daily *= 2.2
          daily *= rnd.uniform(0.90, 1.10)
          rows.append((start + datetime.timedelta(days=t), daily))

      with open("/srv/reports/ingest-daily.csv", "w") as f:
          f.write("date,ingest_gb\n")
          for d, gb in rows:
              f.write("%s,%.3f\n" % (d.isoformat(), gb))
      PY
      chmod 0755 /usr/local/bin/seed-ingest
      python3 /usr/local/bin/seed-ingest

      cat > /etc/ledger/retention.conf <<'CONF'
      # Ledger archive retention. Enforced nightly by ledger-prune.timer.
      # Records older than this are deleted, so the volume holds one window of
      # ingest in the steady state.
      retention_days = 90
      CONF

      cat > /root/questions.txt <<'Q'
      Finance is buying the ledger archive volume for the next eighteen months
      and wants a number today. What you have:

        /srv/reports/ingest-daily.csv   a year of daily ingest, in GB
        /etc/ledger/retention.conf      the retention policy

      Ingest has grown linearly over the year and is expected to continue.
      Assume the shape of the peaks stays as it is while the level rises, and
      size for eighteen months (548 days) after the last date in the file.

      Write /root/answers/capacity.md with one key per line:

        basis=                which window the volume has to survive. One of:
                                mean       the average window across the year
                                trailing   the most recent window
                                peak       the largest window in the year
                                median     the middle window

        peak-window-gb=       the largest amount of data the retention window
                              has ever held, from the file

        projected-window-gb=  that same window eighteen months from now, with
                              the fitted growth applied

        size-gb=              what to buy

      Numbers may be rounded to whole GB.
      Q

      echo "scenario ready — $(( $(wc -l < /srv/reports/ingest-daily.csv) - 1 )) days of ingest in /srv/reports/ingest-daily.csv, retention policy in /etc/ledger/retention.conf"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      if [ ! -s /root/answers/capacity.md ]; then
        echo "not yet: /root/answers/capacity.md is missing or empty"
        echo "         four keys: basis, peak-window-gb, projected-window-gb, size-gb"
        exit 1
      fi

      # The truth is recomputed from the same file the student read, rather than
      # hardcoded here — a lesson whose expected answer is a literal stops being
      # true the moment the seed changes.
      cat > /tmp/grade.py <<'PY'
      import csv
      import re
      import sys

      HORIZON = 548

      with open("/etc/ledger/retention.conf") as f:
          window = int(re.search(r"retention_days\s*=\s*(\d+)", f.read()).group(1))

      with open("/srv/reports/ingest-daily.csv") as f:
          daily = [float(r["ingest_gb"]) for r in csv.DictReader(f)]

      sums = [sum(daily[i:i + window]) for i in range(len(daily) - window + 1)]
      peak = max(sums)
      trailing = sums[-1]
      mean_window = sum(daily) / len(daily) * window

      n = len(daily)
      xs = range(n)
      mx = sum(xs) / n
      my = sum(daily) / n
      slope = sum((x - mx) * (y - my) for x, y in zip(xs, daily)) / sum((x - mx) ** 2 for x in xs)
      intercept = my - slope * mx
      last = n - 1
      ratio = (intercept + slope * (last + HORIZON)) / (intercept + slope * last)
      projected = peak * ratio

      answers = {}
      with open("/root/answers/capacity.md") as f:
          for line in f:
              if "=" in line and not line.strip().startswith("#"):
                  k, _, v = line.partition("=")
                  answers[k.strip().lower()] = v.strip()

      def number(key):
          raw = answers.get(key, "")
          m = re.search(r"-?\d+(?:\.\d+)?", raw.replace(",", ""))
          return float(m.group(0)) if m else None

      def fail(*lines):
          for line in lines:
              print(line)
          sys.exit(1)

      missing = [k for k in ("basis", "peak-window-gb", "projected-window-gb", "size-gb")
                 if k not in answers]
      if missing:
          fail("not yet: capacity.md is missing: %s" % ", ".join(missing))

      basis = answers["basis"].lower()
      if basis != "peak":
          hints = {
              "mean": ("not yet: the mean window is %.0f GB. Half the year is above it, and"
                       % mean_window,
                       "         the volume does not get to be full on average — it either",
                       "         holds the worst window or it fills up during it."),
              "trailing": ("not yet: the trailing window is %.0f GB, and it is not the largest."
                           % trailing,
                           "         The last quarter was quiet. Look further back for the one",
                           "         that was not, and ask whether it is going to happen again."),
              "median": ("not yet: the median window is the one half the year exceeded.",
                         "         Sizing to it means running out roughly half the time."),
          }
          fail(*hints.get(basis, ("not yet: basis='%s' is not one of mean, trailing, peak, median" % basis,)))

      got_peak = number("peak-window-gb")
      if got_peak is None:
          fail("not yet: peak-window-gb is not a number")
      if abs(got_peak - peak) / peak > 0.03:
          fail("not yet: peak-window-gb=%.0f, and the largest %d-day total in the file is"
               % (got_peak, window),
               "         %.0f GB. Roll a %d-day sum across every start date rather than"
               % (peak, window),
               "         taking the biggest days — the window is what the volume holds.")

      got_proj = number("projected-window-gb")
      if got_proj is None:
          fail("not yet: projected-window-gb is not a number")
      if abs(got_proj - projected) / projected > 0.12:
          fail("not yet: projected-window-gb=%.0f, against %.0f GB expected."
               % (got_proj, projected),
               "         Fit the daily series, take the ratio of fitted ingest at day",
               "         %d to day %d, and scale the peak window by it. Growth applies"
               % (last + HORIZON, last),
               "         to the peak as much as to the average.")

      got_size = number("size-gb")
      if got_size is None:
          fail("not yet: size-gb is not a number")
      if got_size < got_proj:
          fail("not yet: size-gb=%.0f is below your own projected window of %.0f GB."
               % (got_size, got_proj),
               "         The volume has to hold the window before it holds any headroom.")
      if got_size < projected * 1.10:
          fail("not yet: size-gb=%.0f leaves %.0f%% headroom over a projected peak of"
               % (got_size, (got_size / projected - 1) * 100),
               "         %.0f GB. The projection is a fit through noisy data and the"
               % projected,
               "         peak is one observation of a thing that recurs. A volume sized",
               "         to the forecast exactly is a volume that fills the first time",
               "         the forecast is low.")
      if got_size > projected * 1.85:
          fail("not yet: size-gb=%.0f is %.1fx the projected peak of %.0f GB."
               % (got_size, got_size / projected, projected),
               "         Headroom is insurance and it is being bought with somebody's",
               "         budget. State a multiple you can defend.")

      print("PASS — peak window %.0f GB identified, projected to %.0f GB at eighteen"
            % (peak, projected))
      print("       months, sized at %.0f GB (%.0f%% headroom) on the peak rather than"
            % (got_size, (got_size / projected - 1) * 100))
      print("       the mean, which would have bought %.0f GB." % (mean_window * ratio))
      PY

      python3 /tmp/grade.py
---
