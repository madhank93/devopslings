---
kind: lesson
title: "The observability bill is three times the budget"
description: |
  Traces, logs and metrics for the fleet cost about $31,000 a month, and
  finance has set the budget at $10,000. Choose a sampling rate, retention
  and cardinality limits per signal, show the arithmetic landing under the
  budget without breaking what the teams must still be able to do, and say
  what each cut stops you answering.
name: observability-cost-budget
slug: observability-cost-budget
createdAt: "2026-11-22"

sandbox:
  stack: obs-stack
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 120
    run: |
      obs-reset >/dev/null
      rm -rf /obs/cost
      mkdir -p /obs/cost
      cat > /obs/cost/USAGE.md <<'MD'
      # What the fleet sends, per month

      ## Traces
      - 6,000 million spans, every trace kept (100% sampling), retained 30 days.
      - 2% of spans belong to traces that contain an error. Tail sampling in the
        gateways can keep every one of those and a percentage of the rest.

      ## Logs
      - 30,000 GB, retained 30 days.
      - By level: debug 55%, info 35%, warn 7%, error 3%.

      ## Metrics
      - 3,000,000 active series, retained 90 days.
      - 1,800,000 of them come from the `user_id` label on
        `http_request_duration_seconds`, one set of histogram series per user.
        Without that label the fleet has 1,200,000 series.
      MD
      cat > /obs/cost/PRICES.md <<'MD'
      # The vendor's price list, per month

      traces   $1.00 per million spans kept, plus $0.05 per million spans per day retained
      logs     $0.15 per GB ingested,        plus $0.005 per GB per day retained
      metrics  $0.0006 per active series,    plus $0.00002 per series per day retained

      Today:  traces  6,000 x (1.00 + 0.05 x 30)        = $15,000
              logs   30,000 x (0.15 + 0.005 x 30)       =  $9,000
              metrics 3,000,000 x (0.0006 + 0.00002 x 90) =  $7,200
              total                                        $31,200

      Budget: $10,000 a month.
      MD
      cat > /obs/cost/REQUIREMENTS.md <<'MD'
      # What the plan may not break

      1. Incident reviews happen up to two weeks after an incident, and need
         every trace that had an error in it.
      2. Security investigations need warn and error logs for 30 days.
      3. SLOs are evaluated over a 28-day window from metrics.
      4. Every metric series except the per-user ones is used by a dashboard or
         an alert.
      MD
      cat > /obs/answers/plan.yaml <<'YML'
      # Your plan. Costs are per month, in dollars; '?' marks what to fill in.
      traces:
        sample_percent: "?"     # % of traces WITHOUT an error that are kept; error traces are always kept
        retention_days: "?"
        cost: "?"
        loses: "?"              # what you can no longer answer because of these cuts
      logs:
        drop_levels: []       # levels no longer ingested at all, e.g. [debug]
        retention_days: "?"
        cost: "?"
        loses: "?"
      metrics:
        max_series: "?"         # the active-series limit you will enforce
        retention_days: "?"
        cost: "?"
        loses: "?"
      total: "?"
      YML
      echo "scenario ready: /obs/cost has the usage, the price list and the requirements."
      echo "Your plan: /obs/answers/plan.yaml"

  verify_done:
    timeout_seconds: 60
    run: |
      python3 - <<'PY'
      import re, sys
      import yaml

      ANSWER = "/obs/answers/plan.yaml"
      BUDGET = 10000
      LEVELS = {"debug": 0.55, "info": 0.35, "warn": 0.07, "error": 0.03}

      def no(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print(l)
          sys.exit(1)

      try:
          p = yaml.safe_load(open(ANSWER)) or {}
      except OSError:
          no(f"{ANSWER} is missing. Reset the lesson to get the template back.")
      except yaml.YAMLError as e:
          no(f"{ANSWER} is not valid YAML: {str(e).splitlines()[0]}")

      def val(sig, k):
          v = (p.get(sig) or {}).get(k) if sig else p.get(k)
          name = f"{sig}.{k}" if sig else k
          if v is None or v == "?":
              no(f"{name} in {ANSWER} is not filled in.")
          return v

      def number(sig, k):
          v = val(sig, k)
          try:
              return float(str(v).replace("$", "").replace(",", "").strip())
          except ValueError:
              no(f"{sig + '.' if sig else ''}{k} is '{v}'; it needs a number.")

      pct, tret = number("traces", "sample_percent"), number("traces", "retention_days")
      drop = (p.get("logs") or {}).get("drop_levels") or []
      drop = [str(x).lower().strip() for x in (drop if isinstance(drop, list) else [drop])]
      lret = number("logs", "retention_days")
      series, mret = number("metrics", "max_series"), number("metrics", "retention_days")
      if not 0 <= pct <= 100:
          no(f"traces.sample_percent is {pct:g}; it is a percentage.")
      for l in drop:
          if l not in LEVELS:
              no(f"logs.drop_levels has '{l}'; the levels are debug, info, warn and error.")

      # The requirements.
      if tret < 14:
          no(f"traces are kept {tret:g} days. Incident reviews happen up to two weeks later and need",
             "every error trace (REQUIREMENTS.md, 1).")
      if "warn" in drop or "error" in drop:
          no("the plan stops ingesting warn or error logs, which security investigations need for 30",
             "days (REQUIREMENTS.md, 2).")
      if lret < 30:
          no(f"logs are kept {lret:g} days, and security needs warn and error logs for 30",
             "(REQUIREMENTS.md, 2). One retention covers every level in this price list.")
      if mret < 28:
          no(f"metrics are kept {mret:g} days. An SLO over a 28-day window needs 28 days of data",
             "(REQUIREMENTS.md, 3).")
      if series < 1200000:
          no(f"max_series is {series:,.0f}. The fleet has 1,200,000 series that dashboards and alerts",
             "use (REQUIREMENTS.md, 4); a limit under that drops some of them at random.")

      # The arithmetic.
      kept = 6000 * (0.02 + 0.98 * pct / 100)
      gb = 30000 * (1 - sum(LEVELS[l] for l in drop))
      cost = {
          "traces": kept * (1.00 + 0.05 * tret),
          "logs": gb * (0.15 + 0.005 * lret),
          "metrics": min(series, 3000000) * (0.0006 + 0.00002 * mret),
      }
      how = {
          "traces": f"6,000M spans x (2% + 98% x {pct:g}%) = {kept:,.0f}M kept, x (1.00 + 0.05 x {tret:g} days)",
          "logs": f"30,000 GB x {1 - sum(LEVELS[l] for l in drop):.0%} = {gb:,.0f} GB, x (0.15 + 0.005 x {lret:g} days)",
          "metrics": f"{min(series, 3000000):,.0f} series x (0.0006 + 0.00002 x {mret:g} days)",
      }
      for sig, c in cost.items():
          said = number(sig, "cost")
          if abs(said - c) > max(c * 0.02, 1):
              no(f"{sig}.cost is {said:,.0f}, and the price list gives a different number for this plan.",
                 f"Work it through: {how[sig]}.")
      total = sum(cost.values())
      said = number(None, "total")
      if abs(said - total) > max(total * 0.02, 1):
          no(f"total is {said:,.0f}; the three signals' costs add up to something else.")
      if total > BUDGET:
          no(f"the plan costs ${total:,.0f} a month, over the ${BUDGET:,} budget.")

      # What each cut costs in answers.
      cuts = {
          "traces": [(pct < 100, r"\b(non-?error|successful|healthy|normal|slow|latency|every request|individual|specific|particular|baseline|compar\w*|sampled[- ]out)\b",
                      "which requests no longer have a trace"),
                     (tret < 30, r"\b(older|weeks?|month|days?|history|historical|retention|back)\b",
                      "how far back traces no longer go")],
          "logs": [(bool(drop), r"\b(debug)\b", "what the debug logs were the only record of"),
                   (lret < 30, r"\b(older|weeks?|month|days?|history|historical|back)\b", "how far back logs no longer go")],
          "metrics": [(series < 3000000, r"\b(user|users|per[- ]user|user_id|customer|individual|single)\b",
                       "which question the per-user series answered"),
                      (mret < 90, r"\b(trends?|older|months?|quarters?|year|seasonal\w*|capacity|history|historical|compar\w*)\b",
                       "what the older metrics were for")],
      }
      for sig, rules in cuts.items():
          made = [r for r in rules if r[0]]
          if not made:
              continue
          text = str(val(sig, "loses")).lower()
          if len(text.split()) < 6:
              no(f"{sig}.loses is '{text}'. Say what a question you can ask today and not after the cut.")
          for _, rx, what in made:
              if not re.search(rx, text):
                  no(f"{sig}.loses does not say {what}. Every cut stops some question being",
                     "answerable; the plan has to say which, so nobody finds out during an incident.")
      print(f"PASS — ${total:,.0f} a month against a ${BUDGET:,} budget: traces ${cost['traces']:,.0f},")
      print(f"logs ${cost['logs']:,.0f}, metrics ${cost['metrics']:,.0f}, every requirement kept and every cut's loss named.")
      PY
---
