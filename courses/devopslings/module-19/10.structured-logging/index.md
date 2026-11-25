---
kind: lesson
title: "Which errors did order 812 hit? Only a regex knows"
description: |
  dispatch logs like it is 2005: a timestamp, a level, and a sentence with
  the order number somewhere in it. Support asks which errors order 812
  hit, and the only answer is a regex that also matches order 8120, shelf
  812 and sku 1812. Make dispatch log records with fields, so the question
  is a filter on a field.
name: structured-logging
slug: structured-logging
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
      cat > /obs/apps/lab.py <<'PY'
      """dispatch — picks paid orders in the warehouse and hands them to couriers.

      Its logs go straight to Loki, one line per record, in the stream
      {service="dispatch"}. Saving this file restarts it; its own errors are in
      /obs/logs/lab.log.
      """
      import json
      import logging
      import random
      import time
      import urllib.request


      class LokiHandler(logging.Handler):
          """Pushes each record to Loki as one line, exactly as the formatter wrote it."""

          def emit(self, record):
              body = {"streams": [{"stream": {"service": "dispatch"},
                                   "values": [[str(int(record.created * 1e9)), self.format(record)]]}]}
              try:
                  urllib.request.urlopen(urllib.request.Request(
                      "http://loki:3100/loki/api/v1/push", data=json.dumps(body).encode(),
                      headers={"Content-Type": "application/json"}), timeout=2).read()
              except Exception:
                  self.handleError(record)


      handler = LokiHandler()
      handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
      log = logging.getLogger("dispatch")
      log.addHandler(handler)
      log.setLevel(logging.INFO)

      WAREHOUSES = ["ams-1", "ams-2", "rtm-1"]
      COURIERS = ["dhl", "postnl", "ups"]
      REASONS = ["parcel over weight limit", "address failed validation", "no pickup slot left"]


      def dispatch(order, warehouse):
          items = random.randint(1, 6)
          log.info("order %s picked in %s, %d items", order, warehouse, items)
          courier = random.choice(COURIERS)
          if random.random() < (0.5 if order == 812 else 0.15):
              log.error("order %s rejected by courier %s in %s: %s", order, courier, warehouse,
                        random.choice(REASONS))
              return
          log.info("order %s handed to %s in %s", order, courier, warehouse)


      while True:
          order = 812 if random.random() < 0.15 else random.choice(
              [8120, 1812, 81] + list(range(800, 900)))
          dispatch(order, random.choice(WAREHOUSES))
          if random.random() < 0.2:
              log.info("restocked shelf %s with %d units of sku %d",
                       random.choice(["A-12", "B-812", "C-4"]), random.randint(10, 90),
                       random.choice([1812, 812, 3344]))
          time.sleep(random.uniform(0.1, 0.3))
      PY
      app_up lab
      echo "scenario ready: dispatch (/obs/apps/lab.py, running in the lab container) logs to"
      echo "Loki in the stream {service=\"dispatch\"}. Look at what it writes:"
      echo "  logcli query '{service=\"dispatch\"}' --since=1m --limit=20"

  verify_done:
    timeout_seconds: 90
    run: |
      python3 - <<'PY'
      import json, re, sys, time, urllib.parse, urllib.request

      LOKI = "http://loki:3100"
      ORDER = "812"

      def no(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print(l)
          sys.exit(1)

      def tail():
          try:
              lines = [l.rstrip() for l in open("/obs/logs/lab.log") if not l.startswith("[supervise]")]
          except OSError:
              lines = []
          return ["  " + l[:200] for l in lines[-4:]] or ["  (nothing)"]

      def query(q, start, end):
          args = urllib.parse.urlencode({"query": q, "start": start, "end": end, "limit": 5000,
                                         "direction": "forward"})
          try:
              with urllib.request.urlopen(f"{LOKI}/loki/api/v1/query_range?{args}", timeout=15) as r:
                  body = json.load(r)
          except urllib.error.HTTPError as e:
              no(f"Loki rejected {q}: {e.read().decode(errors='replace').strip()}")
          except OSError as e:
              no(f"Loki did not answer ({e}).")
          return sorted((int(ts), line) for s in body["data"]["result"] for ts, line in s["values"])

      # Lines from the code as it is now: dispatch restarts within a second of a
      # save, so give it a moment, then read fifteen seconds of its output.
      time.sleep(1.5)
      try:
          started = int(open("/obs/run/lab.started").read())
      except (OSError, ValueError):
          started = 0
      time.sleep(max(0, started + 16 - time.time()))
      start, end = (started + 1) * 10**9, time.time_ns()
      lines = query('{service="dispatch"}', start, end)
      if len(lines) < 20:
          no(f"dispatch has sent {len(lines)} lines to Loki since it last started. Is it running?",
             "The end of /obs/logs/lab.log:", *tail())

      records = []
      for ts, line in lines:
          try:
              rec = json.loads(line)
          except ValueError:
              rec = None
          if not isinstance(rec, dict):
              plain = sum(1 for _, l in lines if not l.lstrip().startswith("{"))
              no(f"{plain} of the {len(lines)} lines dispatch sent since it last started are not JSON objects, e.g.:",
                 f"  {line[:150]}",
                 "| json cannot pull fields out of those, so a filter on order_id never sees them.",
                 "Every record dispatch logs has to be a JSON object, the restock lines included.")
          records.append((ts, line, rec))

      for key in ("level", "msg"):
          missing = [(l, r) for _, l, r in records if key not in r]
          if missing:
              no(f"{len(missing)} of {len(records)} records have no `{key}` key; one has the keys",
                 f"  {', '.join(missing[0][1])}",
                 f"Every record needs `level` and `msg` under exactly those names, so one query works",
                 "for every line.")

      # Records about order 812: a field named for an order holding it, or
      # "order 812" in the text. A shelf or sku numbered 812 is not the order.
      def about(r):
          if any("order" in k.lower() and str(v) == ORDER for k, v in r.items()):
              return True
          return any(re.search(rf"order\D{{0,3}}\b{ORDER}\b", v, re.I) for v in r.values() if isinstance(v, str))
      mine = [(ts, l, r) for ts, l, r in records if about(r)]
      if not mine:
          no(f"no record since dispatch last started mentions order {ORDER}. dispatch handles it",
             "every couple of seconds; did a change stop it logging?")
      loose = [l for _, l, r in mine if str(r.get("order_id")) != ORDER]
      if loose:
          no(f"{len(loose)} records about order {ORDER} have no order_id field holding {ORDER}, e.g.:",
             f"  {loose[0][:160]}",
             "| json | order_id=\"812\" can only find a record whose order_id field is 812.")

      in_msg = [l for _, l, r in mine if re.search(rf"\b{ORDER}\b", str(r.get("msg", "")))]
      if in_msg:
          no(f"order {ORDER} is still inside the msg text of {len(in_msg)} records, e.g.:",
             f"  {in_msg[0][:160]}",
             "msg names what happened, the same text for every order, so you can count by it;",
             "the order belongs in order_id alone.")

      try:
          ans = open("/obs/answers/structured-logging.txt").read()
      except OSError:
          ans = ""
      m = re.search(r"^\s*key\s*:\s*([A-Za-z_][\w.]*)\s*$", ans, re.M | re.I)
      if not m:
          no("/obs/answers/structured-logging.txt needs a line `key: <name>`: the one field besides",
             "level, msg and order_id that every order record now carries.")
      key = m.group(1)
      if key in ("level", "msg", "order_id"):
          no(f"the answer names `{key}`, which is one of the three already required. Name the fourth.")
      orders = [(l, r) for _, l, r in records if "order_id" in r]
      lacking = [l for l, r in orders if key not in r]
      if lacking:
          no(f"the answer names `{key}`, and {len(lacking)} of {len(orders)} order records do not carry it, e.g.:",
             f"  {lacking[0][:160]}",
             "A stable key is one you can rely on: every order record has it, under that name.")

      q = f'{{service="dispatch"}} | json | order_id="{ORDER}"'
      got = query(q, start, end)
      want = [(ts, l) for ts, l, _ in mine]
      if [l for _, l in got] != [l for _, l in want]:
          no(f"`{q}` returns {len(got)} records; {len(want)} are about order {ORDER}.")
      errors = query(q + ' | level=~"(?i)err.*"', start, end)
      if not errors:
          no(f"none of order {ORDER}'s records has an error level, and dispatch logs a rejection for it",
             "about every other time. Keep each record's level as the logger had it.")
      print(f"PASS — `{q}` returns exactly order {ORDER}'s {len(got)} records,")
      print(f"{len(errors)} of them errors, and every order record carries level, msg, order_id and {key}.")
      PY
---
