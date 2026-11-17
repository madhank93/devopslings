---
kind: lesson
title: "Capacity planning"
description: |
  Checkout's peak will be two and a half times today's within a year, and
  the plan on the table is "two and a half times the web nodes". Work out
  what one request actually costs each resource it uses, how much of each
  the peak keeps busy, and which one runs out first. It is not the one on
  the dashboard.
name: capacity-planning
slug: capacity-planning
createdAt: "2026-11-15"

sandbox:
  stack: ha-stack
  service: ops

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      ha-reset
      mkdir -p /var/lib/devopslings /ha/sre/capacity
      cat > /var/lib/devopslings/capgen.py <<'PY'
      #!/usr/bin/env python3
      """capgen SEED — a load test of checkout at today's peak, one row per request.

      Each request spends CPU on a web node, holds a Postgres connection, and
      waits on the payment provider; the total also has network and queueing.
      """
      import math
      import random
      import sys

      rng = random.Random(int(sys.argv[1]))
      lg = lambda mean, s: rng.lognormvariate(0, s) * mean / math.exp(s * s / 2)
      print("request,total_ms,cpu_ms,db_ms,provider_ms")
      for i in range(6000):
          cpu, db, prov = lg(16, 0.5), lg(95, 0.6), lg(180, 0.4)
          print(f"{i + 1},{cpu + db + prov + rng.expovariate(1 / 12):.1f},{cpu:.1f},{db:.1f},{prov:.1f}")
      PY
      cat > /var/lib/devopslings/cap-grade.py <<'PY'
      import csv
      import math
      import re
      import statistics
      import sys

      ANS = "/ha/answers/capacity.txt"
      DATA = "/var/lib/devopslings/loadtest.csv"
      PEAK, TODAY, CORES = 600, 240, 4
      # name: (column, unit, capacity today, what the capacity is)
      RES = {
          "web_cpu": ("cpu_ms", "cores", 2 * CORES, "2 web nodes of 4 vCPU"),
          "db_connections": ("db_ms", "connections", 90, "the 90 connections Postgres leaves the app"),
          "payment_concurrency": ("provider_ms", "calls", 80, "the provider's limit of 80 calls in flight"),
      }


      def fail(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print("         " + l)
          sys.exit(1)


      def num(s, what):
          m = re.search(r"-?[0-9]+(\.[0-9]+)?", s or "")
          if not m:
              fail(f"{what} in {ANS} is '{(s or '').strip() or 'missing'}'; it needs a number.")
          return float(m.group(0))


      near = lambda x, y, r=0.05: abs(x - y) <= r * abs(y)

      rows = list(csv.DictReader(open(DATA)))
      col = lambda c: [float(r[c]) for r in rows]
      mean = {c: statistics.fmean(col(c)) for c in ("total_ms", "cpu_ms", "db_ms", "provider_ms")}
      p99 = {c: statistics.quantiles(col(c), n=100)[98] for c in mean}
      med = {c: statistics.median(col(c)) for c in mean}

      try:
          lines = [l.split("#", 1)[0].strip() for l in open(ANS)]
      except OSError:
          fail(f"{ANS} is missing.")
      fields, res = {}, {}
      for l in lines:
          k, sep, v = l.partition(":")
          k = k.strip().lower()
          if not sep:
              continue
          if k == "resource":
              p = [x.strip() for x in v.split("|")]
              res[p[0].lower()] = p
          else:
              fields[k] = v.strip()

      h = num(fields.get("headroom"), "headroom")
      h = h / 100 if h > 1 else h
      if h >= 0.9:
          fail(f"headroom is {h:.0%}. Planning to run the forecast peak at {h:.0%} of a resource leaves no",
               "room for a forecast that is a little low, a node lost at peak, or the queueing that",
               "makes latency climb long before 100%. Pick a ceiling, usually 60-80%, and plan to it.")
      if h < 0.5:
          fail(f"headroom is {h:.0%}: the plan buys more than twice what the forecast peak uses.",
               "Headroom is the most the peak may use; somewhere between 60% and 80% is usual.")
      peak = num(fields.get("peak"), "peak")
      if peak != PEAK:
          if peak == TODAY:
              fail(f"peak is {peak:g} req/s, today's peak. The plan is for the forecast: the largest peak",
                   "in /ha/sre/capacity/forecast.txt.")
          fail(f"peak is {peak:g} req/s; the forecast's largest peak is a different number.")

      for name, (c, unit, cap, what) in RES.items():
          if name not in res:
              fail(f"the plan has no line for {name}. Every request also holds it, for about {mean[c]:.0f} ms:",
                   f"{what}. A plan that sizes only some of what a request uses",
                   "scales one dimension and runs out of another.")
          p = res[name] + ["", "", ""]
          per, used, planned = num(p[1], f"{name}'s per-request cost"), num(p[2], f"{name}'s in-use"), num(p[3], f"{name}'s planned")
          m = mean[c]
          if not near(per, m):
              why = (f"that is the p99. Little's Law uses the mean time held: the average of the {c} column, {m:.1f} ms" if near(per, p99[c], 0.08) else
                     f"that is the median. Little's Law uses the mean, {m:.1f} ms; the tail makes it higher" if near(per, med[c], 0.03) else
                     f"that is the whole request's mean time. A request does not hold {name} while it waits on everything else: use the {c} column" if near(per, mean["total_ms"]) else
                     f"the mean of the {c} column in the load test is {m:.1f} ms")
              fail(f"{name} costs {per:g} ms per request in the plan; {why}.")
          busy = PEAK * m / 1000
          if not near(used, busy):
              why = (f"{used:g} is the request rate. What is in use is the rate times how long each holds it" if near(used, PEAK, 0.01) else
                     f"{used:g} is in use at today's {TODAY} req/s. The plan is for {PEAK}" if near(used, TODAY * m / 1000) else
                     f"{PEAK} req/s x {m / 1000:.4f} s = {busy:.1f} {unit} busy at once")
              fail(f"{name} in use at peak is {used:g} {unit}; {why} (Little's Law: L = rate x time).")
          if name == "web_cpu":
              need = math.ceil(busy / (CORES * h))
              if planned < need:
                  fail(f"web_cpu: {planned:g} nodes give {planned * CORES:g} cores, and the peak keeps {busy:.1f} busy: {busy / (planned * CORES):.0%},",
                       f"over the {h:.0%} headroom. {need} nodes keep it under.")
              if planned > need + 1:
                  hint = ("That is today's 2 nodes scaled with the traffic. Today's nodes are not full, so nodes do not scale with req/s; busy cores do." if planned == math.ceil(2 * PEAK / TODAY) else
                          "That count comes from the request's whole response time, most of which is spent waiting, not on a CPU." if near(planned, PEAK * mean["total_ms"] / 1000 / (CORES * h), 0.15) else
                          f"Busy cores over usable cores per node gives {need}; {need + 1} if you want one spare for a lost node.")
                  fail(f"web_cpu plans {planned:g} nodes; {busy:.1f} busy cores at {h:.0%} headroom need {need}. {hint}")
          else:
              need = busy / h
              if planned < need:
                  if name == "payment_concurrency":
                      fail(f"payment_concurrency: the peak keeps {busy:.0f} calls in flight to the provider, and the plan allows",
                           f"{planned:g}. Over the limit, calls are rejected, whatever the web tier can take: no number of",
                           f"web nodes fixes this one. At {h:.0%} headroom the contract needs at least {math.ceil(need)}.")
                  fail(f"db_connections: the peak holds {busy:.0f} connections and the plan provides {planned:g}: over",
                       f"the {h:.0%} headroom. It needs at least {math.ceil(need)}.")

      # What runs out first as traffic grows: the resource whose headroom line comes at the lowest rate.
      at = {n: h * cap / (mean[c] / 1000) for n, (c, _, cap, _) in RES.items()}
      first = min(at, key=at.get)
      said = fields.get("saturates_first", "").strip().lower()
      if said != first:
          order = ", ".join(f"{n} at {at[n]:.0f}" for n in sorted(at, key=at.get))
          extra = ("\n         CPU is what the dashboard shows, and it is not the first wall." if said == "web_cpu" else "")
          fail(f"saturates_first is '{said or 'missing'}'. Each resource reaches {h:.0%} of what it has today",
               f"when rate x time = {h:.0%} of capacity: {order} req/s.{extra}")
      sat = num(fields.get("saturates_at"), "saturates_at")
      if not near(sat, at[first]):
          fail(f"saturates_at is {sat:g} req/s. {first} reaches {h:.0%} of its capacity today when rate x",
               f"{mean[RES[first][0]]:.0f} ms = {h:.0%} of {RES[first][2]}: about {at[first]:.0f} req/s.")

      print(f"per request: {mean['cpu_ms']:.1f} ms CPU, {mean['db_ms']:.1f} ms on a connection, {mean['provider_ms']:.1f} ms at the provider")
      print(f"at {PEAK} req/s: {PEAK * mean['cpu_ms'] / 1000:.1f} cores, {PEAK * mean['db_ms'] / 1000:.0f} connections, {PEAK * mean['provider_ms'] / 1000:.0f} provider calls in flight")
      print(f"{first} saturates first, at about {at[first]:.0f} req/s")
      PY
      python3 /var/lib/devopslings/capgen.py "$RANDOM" > /var/lib/devopslings/loadtest.csv
      cp /var/lib/devopslings/loadtest.csv /ha/sre/capacity/loadtest.csv
      cat > /ha/sre/capacity/fleet.txt <<'TXT'
      # What checkout runs on today, and its limits.

      web nodes          2 (web1, web2), 4 vCPU each. A request's CPU time is spent
                         on whichever node serves it.
      Postgres primary   max_connections 100: 3 reserved for superusers, 2 for
                         replication, 5 for backups and monitoring. 90 for the app,
                         across all web nodes. Checkout writes, so the replica
                         cannot take its connections.
      payment provider   contract: at most 80 of our calls in flight at once. Calls
                         over that are rejected with HTTP 429.

      The resources, by the names the plan uses:
        web_cpu              CPU cores on the web nodes
        db_connections       connections held to the primary
        payment_concurrency  calls in flight to the provider
      TXT
      cat > /ha/sre/capacity/forecast.txt <<'TXT'
      # Checkout's busiest minute of each month, in requests per second.
      # Today is month 0. Marketing's forecast, agreed with finance.
      month  peak
        0     240
        2     270
        4     320
        6     380
        8     450
       10     520
       12     600
      TXT
      cat > /ha/sre/capacity/dashboard.txt <<'TXT'
      # The capacity dashboard, at today's peak (240 req/s).
      web1  CPU  49%
      web2  CPU  47%
      pg1   CPU  22%   memory 41%   disk 18%
      TXT
      cat > /ha/sre/capacity/proposal.txt <<'TXT'
      # The plan on the table.
      Traffic goes from 240 to 600 req/s: 2.5x. We run 2 web nodes, so we
      need 5. Order 3 more.
      TXT
      cat > /ha/answers/capacity.txt <<'TXT'
      # Checkout's capacity plan. '#' starts a comment.

      headroom: ?   # the most of any resource the plan lets the peak use, e.g. 70%
      peak: ?       # the request rate the plan is for, in req/s

      # One line per resource checkout uses, named as in fleet.txt:
      #   resource: name | per request | in use at peak | planned
      # per request:     what one request costs it, from the load test (ms)
      # in use at peak:  how much of it the peak keeps busy at once (cores,
      #                  connections, calls)
      # planned:         what the plan provides: nodes for web_cpu, connections
      #                  or calls for the others
      resource: web_cpu | ? ms | ? cores | ? nodes

      saturates_first: ?   # the resource that reaches the headroom line first as traffic grows
      saturates_at: ?      # the request rate at which it does, in req/s
      TXT
      echo "scenario ready — checkout's peak goes from 240 to 600 req/s within a year."
      echo
      echo "  the proposal:   /ha/sre/capacity/proposal.txt"
      echo "  the load test:  /ha/sre/capacity/loadtest.csv   (one row per request, times in ms)"
      echo "  the fleet:      /ha/sre/capacity/fleet.txt"
      echo "  the forecast:   /ha/sre/capacity/forecast.txt"
      echo "  your plan:      /ha/answers/capacity.txt"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 60
    run: |
      g=/var/lib/devopslings/cap-grade.py
      if [ ! -f "$g" ] || [ ! -f /var/lib/devopslings/loadtest.csv ]; then
        echo "not yet: the scenario's files are missing. Reset the lesson."
        exit 1
      fi
      python3 "$g"
      echo
      echo "PASS — counts derived from what each request holds, at the headroom you set, and the first wall named."
---
