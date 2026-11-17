---
kind: lesson
title: "Multi-window burn-rate alerts"
description: |
  The shop's availability alert pages whenever more than 0.1% of requests
  fail over five minutes. It woke someone at 3am for a two-minute blip last
  week, and it paged all through a slow leak that nobody fixed. Replace it
  with alerts on how fast the error budget is burning: a page for the fast
  burn, a ticket for the slow one, and nothing for the blip.
name: multi-burn-rate-alerts
slug: multi-burn-rate-alerts
createdAt: "2026-11-15"

sandbox:
  stack: obs-stack
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 120
    run: |
      obs-reset >/dev/null
      mkdir -p /obs/slo
      cat > /obs/slo/README <<'TXT'
      The shop's SLO
        99.9% of requests to shop succeed (are not 5xx), over 30 days.
        The error budget is the other 0.1%.

      The traffic
        shop_http_requests_total{job="shop", route, code}   a counter per route and status

      Alerting
        severity="page"     wakes someone up, now
        severity="ticket"   lands in the team's queue, for working hours

      Your rules:  /obs/prometheus/rules/slo-burn.yml
      Test them:   promtool check rules /obs/prometheus/rules/slo-burn.yml
      Load them:   obs-reload
      TXT
      cat > /obs/prometheus/rules/slo-burn.yml <<'YML'
      groups:
        - name: shop-slo
          rules:
            - alert: ShopErrorRate
              expr: |
                sum(rate(shop_http_requests_total{job="shop", code=~"5.."}[5m]))
                  / sum(rate(shop_http_requests_total{job="shop"}[5m])) > 0.001
              for: 1m
              labels:
                severity: page
              annotations:
                summary: more than 0.1% of shop requests failing
      YML
      chmod a+r /obs/prometheus/rules/slo-burn.yml
      obs-reload >/dev/null
      echo "scenario ready — the shop's one availability alert is in /obs/prometheus/rules/slo-burn.yml."
      echo
      echo "  the SLO:   /obs/slo/README"
      echo "  the grader replays three histories through your rules with promtool: a fast burn,"
      echo "  a slow burn, and a blip."

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      python3 - <<'PY'
      import os
      import subprocess
      import sys
      import tempfile

      RULES = sys.argv[1] if len(sys.argv) > 1 else "/obs/prometheus/rules/slo-burn.yml"
      PROMTOOL = os.environ.get("PROMTOOL", "promtool").split()
      RPM = 6000            # requests a minute
      BASE = 1              # failures a minute on a normal day
      CLEAN = 3 * 1440      # three days of history before anything happens


      def fail(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print("         " + l)
          sys.exit(1)


      def series(phases):
          """phases: [(minutes, errors per minute)] after CLEAN clean minutes -> (ok, err) value strings."""
          ok, err, t, parts_ok, parts_err = 0, 0, 0, [], []
          for n, e in [(CLEAN, BASE)] + phases:
              first = t == 0
              o0, e0 = (0, 0) if first else (ok + RPM - e, err + e)
              cnt = n if first else n - 1
              parts_ok.append(f"{o0}+{RPM - e}x{cnt}")
              parts_err.append(f"{e0}+{e}x{cnt}")
              ok, err = o0 + (RPM - e) * cnt, e0 + e * cnt
              t += n
          return " ".join(parts_ok), " ".join(parts_err)


      def check(phases, at_mins, severity, want):
          """True when, at each of CLEAN + at_mins minutes, whether an alert with that severity is firing == want."""
          ok, err = series(phases)
          expr = f'clamp_max(count(ALERTS{{alertstate="firing",severity="{severity}"}}), 1) or vector(0)'
          test = f"""rule_files: [{os.path.abspath(RULES)}]
      evaluation_interval: 1m
      tests:
        - interval: 1m
          input_series:
            - series: 'shop_http_requests_total{{job="shop",instance="shop:9101",route="/checkout",code="200"}}'
              values: '{ok}'
            - series: 'shop_http_requests_total{{job="shop",instance="shop:9101",route="/checkout",code="500"}}'
              values: '{err}'
          promql_expr_test:
      """ + "".join(f"""      - expr: '{expr}'
              eval_time: {CLEAN + m}m
              exp_samples:
                - labels: '{{}}'
                  value: {1 if want else 0}
      """ for m in at_mins)
          with tempfile.NamedTemporaryFile("w", suffix=".yml", delete=False) as f:
              f.write(test)
          try:
              r = subprocess.run(PROMTOOL + ["test", "rules", f.name], capture_output=True, text=True)
          finally:
              os.unlink(f.name)
          if r.returncode != 0 and "exp:" not in r.stdout + r.stderr:
              fail("promtool could not run the rules against test data:", *(r.stdout + r.stderr).strip().splitlines()[-4:])
          return r.returncode == 0


      if not os.path.exists(RULES):
          fail(f"{RULES} is missing.")
      r = subprocess.run(PROMTOOL + ["check", "rules", RULES], capture_output=True, text=True)
      if r.returncode != 0:
          fail(f"promtool check rules rejects {RULES}:", *(r.stdout + r.stderr).strip().splitlines()[-4:])

      fast = [(20, 1200), (120, BASE)]          # 20% failing for 20 minutes: 200x the budget rate
      slow = [(30 * 60, 18)]                    # 0.3% failing, for 30 hours: 3x
      blip = [(2, 600), (60, BASE)]             # 10% failing for 2 minutes

      if not check(fast, [10], "page", True):
          if check(fast, [25], "page", True):
              fail("20% of requests failed, burning the budget 200 times faster than the SLO allows, and the",
                   "page fired, but more than 10 minutes in. At that rate every minute of waiting costs",
                   "about 0.5% of the month's budget. The windows already ride out a blip; a long for: on",
                   "top of them only delays the page.")
          fail("20% of requests failed for 10 minutes, burning the budget 200 times faster than the SLO",
               "allows, and no alert with severity=\"page\" was firing. At that rate the month's budget",
               "is gone in under four hours: this is the burn that wakes someone up. The thresholds are",
               "burn rates times the 0.1% the SLO allows to fail, compared with the error ratio.")
      print("fast burn (20% failing): paged within 10 minutes")
      if not check(fast, [60], "page", False):
          fail("the fast burn ended at minute 20, and at minute 60 the page was still firing. A long window",
               "remembers the burn for its whole length after it stops; a short window alongside it, both",
               "required, lets the page resolve soon after the errors do.")
      print("  and stopped paging after it ended")
      if not check(slow, range(30, 30 * 60 + 1, 30), "page", False):
          fail("0.3% of requests failing (3x the budget rate) for 30 hours paged. At that rate the month's",
               "budget lasts ten days: someone should fix it this week, in working hours. That is a",
               "ticket. Paging on it trains people to ignore pages.")
      if not check(slow, [30 * 60], "ticket", True):
          fail("0.3% of requests failed for 30 hours, 3x the budget rate, and no alert with",
               "severity=\"ticket\" was firing. At that rate the budget is gone in ten days, and nothing",
               "told anyone. A slow burn needs a long window (days) and a threshold near 1x.")
      print("slow burn (0.3% for 30h): a ticket, never a page")
      for sev in ("page", "ticket"):
          if not check(blip, range(1, 61), sev, False):
              fail(f"10% of requests failed for 2 minutes, and within the hour after it a {sev} fired.",
                   "That blip spent under half a percent of the month's budget. A short window on its own sees",
                   "a spike as a burn; require the long window too.")
      print("blip (10% for 2 minutes): neither")
      PY
      echo
      echo "PASS — the fast burn pages, the slow burn opens a ticket, and the blip does neither."
---
