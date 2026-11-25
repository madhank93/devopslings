---
kind: lesson
title: "The payments page goes off for every declined card, three times over"
description: |
  The team wanted a page when payments start failing, and wrote a Loki rule
  for it. It pages for a single declined card, for lines that mention an
  error and are not one, and in a real outage it pages once per pod. Make
  it page once when payments fail at a rate that means an outage, and stay
  quiet otherwise.
name: alert-on-a-log
slug: alert-on-a-log
createdAt: "2026-11-23"

sandbox:
  stack: obs-stack
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 120
    run: |
      obs-reset >/dev/null
      . /usr/local/lib/obs.sh
      cat > /obs/loki-rules/fake/rules.yaml <<'YML'
      # Loki ruler rules, in Prometheus rule-file format with LogQL expressions.
      # Every *.yaml in this directory is loaded; the ruler re-reads it every 5
      # seconds and sends alerts to Alertmanager.
      groups:
        - name: payments
          rules:
            - alert: PaymentsErroring
              expr: sum by (pod) (count_over_time({service="payments"} |= "error" [1m])) > 0
              labels:
                severity: page
              annotations:
                summary: payments is logging errors
      YML
      # The last thirty minutes of payments' logs, from its three pods: a
      # declined card now and then, and an outage of the card processor that
      # started twelve minutes ago and lasted three.
      python3 - <<'PY'
      import json, random, time, urllib.request
      rnd = random.Random()
      end = time.time()
      start = end - 1800
      pods = [f"payments-{rnd.randrange(16**6):06x}-{rnd.choice('bcdfghjklmnpqrstvwxz')}{rnd.randrange(100, 999)}" for _ in range(3)]
      outage = (end - 720, end - 540)
      strays = [start + 120 + i * 230 + rnd.uniform(0, 60) for i in range(7)]
      streams = {p: [] for p in pods}
      def rec(t, pod, level, msg, **kw):
          streams[pod].append([str(int(t * 1e9)), json.dumps(dict(level=level, msg=msg, order_id=f"ord-{rnd.randrange(10**6, 10**7)}", **kw))])
      for pod in pods:
          t = start + rnd.uniform(0, 2)
          while t < end:
              if outage[0] <= t < outage[1]:
                  rec(t, pod, "error", "payment failed", reason="processor timeout after 5s")
              elif rnd.random() < 0.12:
                  rec(t, pod, "info", "processor returned a retryable error, retried", attempt=2)
              else:
                  rec(t, pod, "info", "payment captured", amount=rnd.randint(5, 400))
              t += rnd.uniform(1.5, 2.5)
      for t in strays:
          if not outage[0] - 60 <= t < outage[1] + 60:
              rec(t, rnd.choice(pods), "error", "payment failed", reason="card declined by issuer")
      body = {"streams": [{"stream": {"service": "payments", "pod": p}, "values": sorted(v)} for p, v in streams.items()]}
      urllib.request.urlopen(urllib.request.Request("http://loki:3100/loki/api/v1/push", data=json.dumps(body).encode(),
                                                    headers={"Content-Type": "application/json"}), timeout=30).read()
      PY
      echo "scenario ready: the rule is /obs/loki-rules/fake/rules.yaml; Loki's ruler rereads it every 5s"
      echo "and sends to Alertmanager, whose pages land in sink. The last 30 minutes of payments' logs"
      echo "are in Loki, in {service=\"payments\"}. See what the rule would have done:"
      echo "  logcli query 'sum by (pod) (count_over_time({service=\"payments\"} |= \"error\" [1m])) > 0' --since=30m --step=30s"

  verify_done:
    timeout_seconds: 240
    run: |
      python3 - <<'PY'
      import glob, json, os, random, re, sys, time, urllib.parse, urllib.request, uuid
      import yaml

      LOKI, AM = "http://loki:3100", "http://alertmanager:9093"

      def no(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print(l)
          sys.exit(1)

      def get(url):
          with urllib.request.urlopen(url, timeout=15) as r:
              return json.load(r)

      def seconds(d):
          parts = re.findall(r"(\d+)(ms|s|m|h)", str(d or "0s"))
          return sum(int(n) * {"ms": 0.001, "s": 1, "m": 60, "h": 3600}[u] for n, u in parts)

      # The rules, as written and as the ruler has them.
      rules = []
      for p in sorted(glob.glob("/obs/loki-rules/fake/*.y*ml")):
          try:
              doc = yaml.safe_load(open(p)) or {}
          except yaml.YAMLError as e:
              no(f"{p} is not valid YAML:", f"  {str(e).splitlines()[0]}")
          for g in doc.get("groups") or []:
              rules += [r for r in g.get("rules") or [] if "alert" in r]
      if not rules:
          no("there is no alerting rule under /obs/loki-rules/fake/.")
      names = {r["alert"] for r in rules}
      newest = max(os.stat(p).st_mtime for p in glob.glob("/obs/loki-rules/fake/*"))
      time.sleep(max(0, newest + 12 - time.time()))
      try:
          loaded = get(f"{LOKI}/prometheus/api/v1/rules")["data"]["groups"]
      except OSError as e:
          no(f"Loki's ruler did not answer ({e}).")
      have = {r["name"]: r for g in loaded for r in g["rules"] if r.get("type") == "alerting"}

      # The ruler reports each expression in Loki's canonical form.
      def canonical(expr):
          args = urllib.parse.urlencode({"query": expr})
          try:
              return get(f"{LOKI}/loki/api/v1/format_query?{args}")["data"]
          except OSError:
              return None
      for r in rules:
          if r["alert"] not in have or have[r["alert"]].get("query") != canonical(str(r.get("expr", ""))):
              no(f"Loki's ruler has not loaded the rule {r['alert']} as it is in the file. A rule file",
                 "it cannot parse is skipped, with the reason in Loki's own log. Check the expression",
                 "with logcli first:", f"  logcli query --since=10m '{str(r.get('expr', '')).strip()}'")

      # Replay a quarter of an hour of payments, with a fresh label so only
      # this replay is seen: declined cards at minutes 2, 5 and 8, then a
      # processor outage from minute 10 to 13, all three pods failing.
      run = uuid.uuid4().hex[:10]
      t0 = int(time.time()) - 3600
      OUT0, OUT1 = t0 + 600, t0 + 780
      rnd = random.Random()
      pods = [f"payments-{rnd.randrange(16**6):06x}-{c}{rnd.randrange(100, 999)}" for c in "kqx"]
      streams = {p: [] for p in pods}
      events = []
      def rec(t, pod, level, msg, **kw):
          line = json.dumps(dict(level=level, msg=msg, order_id=f"ord-{rnd.randrange(10**6, 10**7)}", **kw))
          streams[pod].append([str(int(t * 1e9)), line])
          if level == "error":
              events.append((t, pod, line))
      for pod in pods:
          t = t0 + rnd.uniform(0, 2)
          while t < t0 + 900:
              if OUT0 <= t < OUT1:
                  rec(t, pod, "error", "payment failed", reason="processor timeout after 5s")
              elif rnd.random() < 0.12:
                  rec(t, pod, "info", "processor returned a retryable error, retried", attempt=2)
              else:
                  rec(t, pod, "info", "payment captured", amount=rnd.randint(5, 400))
              t += rnd.uniform(1.5, 2.5)
      for i, m in enumerate((2, 5, 8)):
          rec(t0 + m * 60 + 17, pods[i], "error", "payment failed", reason="card declined by issuer")
      for p, v in streams.items():
          body = {"streams": [{"stream": {"service": "payments", "pod": p, "check": run}, "values": sorted(v)}]}
          urllib.request.urlopen(urllib.request.Request(f"{LOKI}/loki/api/v1/push", data=json.dumps(body).encode(),
                                                        headers={"Content-Type": "application/json"}), timeout=30).read()

      def only_this_run(expr):
          return re.sub(r"\{(?=\s*[A-Za-z_]\w*\s*(?:=~|!~|!=|=))", '{check="' + run + '", ', expr)

      def at(t):
          return f"minute {(t - t0) / 60:.1f}"

      STEP = 5
      pages = []   # (fire time, alert name, labels)
      for r in rules:
          hold = seconds(r.get("for"))
          args = urllib.parse.urlencode({"query": only_this_run(str(r["expr"])), "start": t0, "end": t0 + 900,
                                         "step": STEP})
          try:
              res = get(f"{LOKI}/loki/api/v1/query_range?{args}")["data"]["result"]
          except urllib.error.HTTPError as e:
              no(f"Loki cannot evaluate the expression of {r['alert']}:", f"  {e.read().decode(errors='replace').strip()[:300]}")
          for s in res:
              labels = {k: v for k, v in s["metric"].items() if k != "check"}
              ts = sorted(int(float(v[0])) for v in s["values"])
              begin = prev = None
              for t in ts + [None]:
                  if t is not None and prev is not None and t - prev <= STEP:
                      prev = t
                      continue
                  if begin is not None and prev - begin >= hold:
                      pages.append((begin + hold, r["alert"], labels))
                  begin = prev = t

      def show(labels):
          return "{" + ", ".join(f'{k}="{v}"' for k, v in sorted(labels.items())) + "}"

      early = sorted((p for p in pages if p[0] < OUT0), key=lambda p: p[0])
      if early:
          t, name, labels = early[0]
          near = [l for e, _, l in events if t - 600 <= e <= t]
          retry = sum(1 for v in streams.values() for ts, l in v if t - 60 <= int(ts) / 1e9 <= t and "retryable" in l)
          what = (f"the only error-level lines in the ten minutes before were {len(near)} declined card(s), one at a time"
                  if near else "no line at error level had been logged yet")
          no(f"replayed against a quarter of an hour of payments' logs, your rule pages at {at(t)} of the",
             f"replay as {name}{show(labels)}, before the outage at minute 10. By then {what},",
             f"and the last minute had {retry} info lines that say \"retryable error\".",
             "A page has to mean the payments are failing, not that one did.")
      during = [p for p in pages if OUT0 <= p[0] <= OUT0 + 120]
      if not during:
          late = sorted((p for p in pages if p[0] > OUT0 + 120), key=lambda p: p[0])
          errs = sum(1 for e, _, _ in events if OUT0 <= e < OUT1)
          if late:
              no(f"in the replay, payments fail on every pod from minute 10 to 13 ({errs} failures), and",
                 f"your rule first pages at {at(late[0][0])}. The page has to go out within two minutes.")
          slow = [f"{r['alert']} has for: {r['for']}" for r in rules if seconds(r.get("for")) >= 180]
          no(f"in the replay, payments fail on every pod from minute 10 to 13 ({errs} failures, about",
             f"{errs / 3:.0f} a minute), and your rule never pages.",
             *([f"{'; '.join(slow)}: the outage is over before the condition has held that long."] if slow else []))
      alerts = sorted({(name, show(labels)) for _, name, labels in during})
      if len(alerts) > 1:
          no(f"in the replay, the one outage from minute 10 to 13 pages {len(alerts)} times:",
             *[f"  {n}{l}" for n, l in alerts],
             "Each distinct label set is its own alert. The outage is one thing happening to",
             "payments; one alert says so.")
      name, labels = alerts[0]

      # Live: an outage now has to reach Alertmanager as that one alert.
      def firing():
          got = get(f"{LOKI}/prometheus/api/v1/rules")["data"]["groups"]
          return {(r["name"], show({k: v for k, v in a["labels"].items() if k not in ("alertname", "check")}))
                  for g in got for r in g["rules"] if r.get("type") == "alerting"
                  for a in r.get("alerts", []) if a.get("state") == "firing"}
      def in_am():
          return {(a["labels"].get("alertname"), show({k: v for k, v in a["labels"].items() if k not in ("alertname", "check")}))
                  for a in get(f"{AM}/api/v2/alerts?active=true&silenced=false&inhibited=false")}
      live = f"{run}l"
      deadline = time.time() + 160
      while True:
          now = time.time()
          for p in pods:
              body = {"streams": [{"stream": {"service": "payments", "pod": p, "check": live},
                                   "values": [[str(int(now * 1e9)), json.dumps({"level": "error", "msg": "payment failed",
                                                                                 "order_id": f"ord-{rnd.randrange(10**6, 10**7)}",
                                                                                 "reason": "processor timeout after 5s"})]]}]}
              urllib.request.urlopen(urllib.request.Request(f"{LOKI}/loki/api/v1/push", data=json.dumps(body).encode(),
                                                            headers={"Content-Type": "application/json"}), timeout=10).read()
          f = firing()
          if f and f <= in_am():
              break
          if time.time() > deadline:
              if f:
                  no(f"Loki's ruler has {', '.join(n + l for n, l in sorted(f))} firing, and Alertmanager never got it.")
              no(f"payments have been failing on every pod for 160 seconds, live, and Loki's ruler has",
                 "fired nothing. The replay says your rule would have paged within two minutes; check",
                 "its state with: curl -s loki:3100/prometheus/api/v1/rules | jq")
          time.sleep(2)
      f = firing()
      if len(f) > 1:
          no(f"a live outage has Loki's ruler firing {len(f)} alerts:", *[f"  {n}{l}" for n, l in sorted(f)])
      n, l = next(iter(f))
      print(f"PASS — replayed, your rule stays quiet through three declined cards and steady retries,")
      print(f"and pages once, as {name}{labels}, within two minutes of an outage. Live, the outage")
      print(f"reaches Alertmanager as one alert, {n}{l}.")
      PY
---
