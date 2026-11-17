---
kind: lesson
title: "SLO and error budget"
description: |
  The shop's SLO is 99.5% of customer requests good, over 30 days. Here are
  the 30 days, minute by minute. Work out the budget, what is left of it, and
  what the outage on the night of 26 October actually cost — in requests,
  not in minutes.
name: slo-and-error-budget
slug: slo-and-error-budget
createdAt: "2026-11-14"

sandbox:
  stack: ha-stack
  service: ops

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      ha-reset
      mkdir -p /var/lib/devopslings /ha/sre
      cat > /var/lib/devopslings/budgetgen.py <<'PY'
      #!/usr/bin/env python3
      """budgetgen SEED — 30 days of per-minute SLI counts for the shop, as CSV.

      minute,valid,good. Traffic follows the day; a background of stray failures,
      an outage at night on 26 October and a partial one at peak on 3 November.
      """
      import math
      import random
      import sys
      from datetime import datetime, timedelta

      rng = random.Random(int(sys.argv[1]))
      start = datetime(2026, 10, 14)
      night = (datetime(2026, 10, 26, 3, 12), datetime(2026, 10, 26, 4, 41), 0.4)
      peak = (datetime(2026, 11, 3, 14, 0), datetime(2026, 11, 3, 14, 20), 0.5)
      print("minute,valid,good")
      for i in range(30 * 1440):
          t = start + timedelta(minutes=i)
          hour = t.hour + t.minute / 60
          rate = 8 + 112 * max(0.0, math.sin(math.pi * (hour - 6) / 16)) ** 2 if 6 <= hour < 22 else 8
          valid = max(0, int(rng.gauss(rate, math.sqrt(rate))))
          p_bad = 0.001
          for a, b, frac in (night, peak):
              if a <= t < b:
                  p_bad = frac
          bad = sum(rng.random() < p_bad for _ in range(valid))
          print(f"{t:%Y-%m-%dT%H:%M},{valid},{valid - bad}")
      PY
      python3 /var/lib/devopslings/budgetgen.py "$RANDOM" > /var/lib/devopslings/requests-30d.csv
      cp /var/lib/devopslings/requests-30d.csv /ha/sre/requests-30d.csv
      cat > /ha/answers/budget.txt <<'TXT'
      # The shop's SLO: 99.5% of valid requests good, over the 30 days in
      # /ha/sre/requests-30d.csv. Plain numbers; decimals are fine.
      valid_requests: ?
      error_budget_requests: ?
      failed_requests: ?
      # What is left of the budget, as a percentage of it. Negative if overspent.
      budget_remaining_percent: ?

      # The outage in the early hours of 26 October.
      # The share of the 30-day error budget it spent, as a percentage:
      night_incident_budget_percent: ?
      # How fast it was spending the budget while it lasted:
      night_incident_burn_rate: ?
      TXT
      echo "scenario ready — 30 days of the shop's SLI, one row per minute."
      echo
      echo "  the data:     /ha/sre/requests-30d.csv   (minute,valid,good)"
      echo "  the SLO:      99.5% of valid requests good, over those 30 days"
      echo "  your answer:  /ha/answers/budget.txt"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 60
    run: |
      src=/var/lib/devopslings/requests-30d.csv
      a=/ha/answers/budget.txt
      if [ ! -f "$src" ]; then
        echo "not yet: the scenario's copy of the data is missing. Reset the lesson."
        exit 1
      fi
      read -r V G F IV IF IMIN < <(awk -F, 'NR > 1 { v += $2; g += $3 }
        $1 >= "2026-10-26T03:12" && $1 < "2026-10-26T04:41" { iv += $2; ib += $2 - $3; n++ }
        END { print v, g, v - g, iv, ib, n }' "$src")
      calc() { awk "BEGIN { printf \"%.6f\", $1 }"; }
      B=$(calc "$V * 0.005")
      val() { sed -n "s/^[[:space:]]*$1[[:space:]]*:[[:space:]]*//p" "$a" 2>/dev/null | head -1 | tr -d ' \t,%' || true; }
      near() { awk -v x="$1" -v y="$2" -v r="$3" 'BEGIN { d = x - y; if (d < 0) d = -d; m = y < 0 ? -y : y; exit !(d <= r * m || d <= 0.5) }'; }
      num() {  # num <field> — sets ans, or fails when it is not a number
        ans=$(val "$1")
        if ! [[ $ans =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
          echo "not yet: $1 in $a is '${ans:-missing}'; it needs a number."
          exit 1
        fi
      }

      num valid_requests
      if ! near "$ans" "$V" 0; then
        if near "$ans" "$G" 0; then
          echo "not yet: valid_requests is the sum of the good column. Valid is every request that counts,"
          echo "         good or not: the 'valid' column."
        elif near "$ans" 43200 0; then
          echo "not yet: valid_requests is $ans, the number of minutes in 30 days. The budget is counted in"
          echo "         requests: add up the 'valid' column."
        else
          echo "not yet: valid_requests is $ans; adding up the 'valid' column over the 30 days gives a different number."
        fi
        exit 1
      fi
      echo "valid requests: $V"

      num error_budget_requests
      if ! near "$ans" "$B" 0.0005; then
        if near "$ans" "$(calc "$V * 0.995")" 0.001; then
          echo "not yet: error_budget_requests is $ans, which is 99.5% of the valid requests: the ones that must"
          echo "         succeed. The budget is the other 0.5%, the ones allowed to fail."
        elif near "$ans" 216 0.01; then
          echo "not yet: error_budget_requests is $ans: 0.5% of the minutes in 30 days. That is a time-based budget,"
          echo "         and it assumes every minute carries the same traffic. Count requests."
        else
          echo "not yet: error_budget_requests is $ans. At 99.5%, 0.5% of the $V valid requests may fail."
        fi
        exit 1
      fi
      echo "error budget: $(printf %.0f "$B") requests"

      num failed_requests
      if ! near "$ans" "$F" 0; then
        echo "not yet: failed_requests is $ans; valid minus good, over the 30 days, is a different number."
        exit 1
      fi
      echo "failed: $F"

      num budget_remaining_percent
      R=$(calc "($B - $F) / $B * 100")
      if ! near "$ans" "$R" 0.01; then
        if near "$ans" "$(calc "$F / $B * 100")" 0.01; then
          echo "not yet: budget_remaining_percent is $ans, which is the share of the budget already spent."
          echo "         The question is what is left."
        else
          echo "not yet: budget_remaining_percent is $ans. With $F failures against a budget of $(printf %.0f "$B"),"
          echo "         what share of the budget has not been used?"
        fi
        exit 1
      fi
      echo "remaining: $(printf %.1f "$R")%"

      num night_incident_budget_percent
      P=$(calc "$IF / $B * 100")
      if ! near "$ans" "$P" 0.1; then
        T=$(calc "$IMIN / 216 * 100")
        if near "$ans" "$T" 0.15 || near "$ans" "$(calc "$T * 0.4")" 0.15; then
          echo "not yet: night_incident_budget_percent is $ans: that is the outage's minutes against a budget"
          echo "         of 216 minutes. Those minutes were at night, when the shop gets a handful of"
          echo "         requests a minute. Count the requests it failed against the request budget."
        else
          echo "not yet: night_incident_budget_percent is $ans. Find where the outage starts and ends in the"
          echo "         data, add up the requests that failed in between, and compare with the whole budget."
        fi
        exit 1
      fi
      echo "the night outage spent $(printf %.1f "$P")% of the budget"

      num night_incident_burn_rate
      E=$(calc "$IF / $IV")
      K=$(calc "$E / 0.005")
      if ! near "$ans" "$K" 0.1; then
        if near "$ans" "$E" 0.15 || near "$ans" "$(calc "$E * 100")" 0.15; then
          echo "not yet: night_incident_burn_rate is $ans, the outage's error rate. Burn rate is that error"
          echo "         rate divided by the rate the SLO allows (0.5%): how many times faster than"
          echo "         'exactly on budget' it was spending."
        else
          echo "not yet: night_incident_burn_rate is $ans. During the outage, what share of requests failed,"
          echo "         and how many times the SLO's allowed 0.5% is that?"
        fi
        exit 1
      fi
      echo "burn rate during it: $(printf %.0f "$K")x"
      echo
      echo "PASS — the budget is counted in requests, and the night outage cost $(printf %.1f "$P")% of it, not $(printf %.0f "$(calc "$IMIN / 216 * 100")")%."
---
