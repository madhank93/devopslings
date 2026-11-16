---
kind: lesson
title: "One payment failed, and the log line that says why is not in Loki"
description: |
  A customer's card was declined twenty minutes ago and support wants the
  reason. The line that explains it sits in a file on one machine, and the
  team has just stood up Loki. Get that one line into Loki, labelled so it
  can be found again, and find it with a query.
name: ship-one-log-line
slug: ship-one-log-line
createdAt: "2026-11-14"

sandbox:
  stack: obs-stack
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 120
    run: |
      obs-reset >/dev/null
      # Forty lines from payments, twenty minutes old, one of them the decline.
      # The order id is new on every start, so an earlier attempt's entries in
      # Loki never match this one.
      python3 - <<'PY'
      import datetime, json, random
      rnd = random.Random()
      start = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=21)
      bad = rnd.randrange(12, 30)
      oid = f"ord-{rnd.randrange(10000, 99999)}"
      lines = []
      for i in range(40):
          t = start + datetime.timedelta(seconds=i * 3 + rnd.random())
          rec = {"ts": t.isoformat(timespec="milliseconds").replace("+00:00", "Z"),
                 "level": "info", "service": "payments",
                 "order_id": f"ord-{rnd.randrange(10000, 99999)}",
                 "customer": f"c-{rnd.randrange(1000, 9999)}", "msg": "payment captured"}
          if i == bad:
              rec.update(level="error", order_id=oid, msg="payment declined: card expired")
          elif i % 9 == 4:
              rec.update(level="warn", msg="card network slow, retried")
          lines.append(json.dumps(rec, separators=(",", ":")))
      open("/obs/logs/payments.log", "w").write("\n".join(lines) + "\n")
      open("/obs/run/declined-order", "w").write(oid + "\n")
      PY
      oid=$(cat /obs/run/declined-order)
      echo "scenario ready: /obs/logs/payments.log has 40 lines from payments. One of them is"
      echo "the decline for order $oid. Loki is at http://loki:3100 (logcli is on the PATH)."
      echo "Write your query to /obs/queries/declined.logql and your answer to"
      echo "/obs/answers/ship-one-log-line.txt."

  verify_done:
    timeout_seconds: 60
    run: |
      . /usr/local/lib/obs.sh
      python3 - <<'PY'
      import datetime, json, re, sys, time, urllib.parse, urllib.request

      LOKI = "http://loki:3100"
      oid = open("/obs/run/declined-order").read().strip()
      record = next(l.rstrip("\n") for l in open("/obs/logs/payments.log") if f'"{oid}"' in l)
      rec = json.loads(record)

      def no(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print(l)
          sys.exit(1)

      def query(q):
          now = time.time_ns()
          args = urllib.parse.urlencode({"query": q, "start": now - 3 * 3600 * 10**9,
                                         "end": now + 300 * 10**9, "limit": 100, "direction": "forward"})
          try:
              with urllib.request.urlopen(f"{LOKI}/loki/api/v1/query_range?{args}", timeout=15) as r:
                  body = json.load(r)
          except urllib.error.HTTPError as e:
              return None, e.read().decode(errors="replace").strip()
          except OSError as e:
              return None, f"Loki unreachable: {e}"
          entries = [(s["stream"], int(ts), line) for s in body["data"]["result"] for ts, line in s["values"]]
          return entries, None

      def show(labels):
          return "{" + ", ".join(f'{k}="{v}"' for k, v in sorted(labels.items())) + "}"

      try:
          q = open("/obs/queries/declined.logql").read().strip()
      except OSError:
          q = ""
      if not q:
          no("/obs/queries/declined.logql is missing or empty. Write the LogQL query that finds",
             f"the decline for {oid} there.")

      found, err = query(q)
      if err:
          no(f"Loki rejected the query in declined.logql:", f"  {q}", f"  {err}")
      found = [e for e in found if oid in e[2]]
      if not found:
          # Is it in Loki at all? Search under every label name Loki knows.
          names = []
          try:
              with urllib.request.urlopen(f"{LOKI}/loki/api/v1/labels?since=3h", timeout=10) as r:
                  names = json.load(r).get("data", [])
          except OSError:
              pass
          def anywhere(text, keep=lambda line: True):
              hits = []
              for n in names:
                  got, _ = query(f'{{{n}=~".+"}} |= `{text}`')
                  hits += [show(s) for s, _, l in got or [] if keep(l)]
              return sorted(set(hits))
          where = anywhere(oid)
          if where:
              no(f"your query finds nothing for {oid}, and Loki does have it, in the stream",
                 f"  {where[0]}",
                 "Your stream selector picks no stream that holds it.")
          # The message alone, without the order, from an earlier full push or not.
          if anywhere(rec["msg"], lambda line: "order_id" not in line):
              no(f"Loki has \"{rec['msg']}\", and no line in it mentions {oid}. The line was",
                 "pushed without the rest of the record: which order, which customer, when. Push",
                 "the whole line as payments wrote it.")
          no(f"nothing in Loki contains {oid}. Push the line to {LOKI}/loki/api/v1/push",
             "(the push body is in the lesson), then look for it with logcli or curl.")
      if len(found) > 1:
          no(f"your query returns {len(found)} entries for {oid}:",
             *[f"  {show(s)} {l[:70]}" for s, _, l in found],
             "Loki keeps every push and has no undo. Restart the lesson for a fresh order id",
             "and push once.")

      labels, ts, line = found[0]
      if line.strip() != record:
          missing = [k for k in rec if f'"{k}"' not in line]
          if missing:
              no(f"the entry in Loki is not the whole record; it lacks {', '.join(missing)}:",
                 f"  {line[:120]}",
                 "Push the line exactly as payments wrote it. Labels choose the stream; the line",
                 "keeps every detail.")
          no("the entry in Loki differs from the line payments wrote:", f"  Loki:     {line[:110]}",
             f"  payments: {record[:110]}", "Push the line unchanged.")

      unique = {k: v for k, v in rec.items() if k in ("order_id", "customer", "ts", "msg")}
      bad = [k for k, v in labels.items() if k in unique or v in unique.values()]
      if bad:
          no(f"the stream is {show(labels)}.",
             f"{', '.join(bad)} is different on every event, so as a label it makes a new stream per",
             "order: Loki indexes, stores and lists each one separately, forever. Keep it in the",
             "line, where a filter like |= finds it.")
      if labels.get("service") != "payments" or labels.get("level") != "error":
          no(f"the stream is {show(labels)}. Label it with where it came from and how bad it is:",
             'service="payments" and level="error".')
      want = round(datetime.datetime.fromisoformat(rec["ts"].replace("Z", "+00:00")).timestamp() * 1000) * 10**6
      if abs(ts - want) > 10**6:
          when = lambda ns: time.strftime("%H:%M:%S", time.gmtime(ns / 1e9))
          no(f"Loki has the entry at {when(ts)} UTC; payments logged it at {when(want)} UTC (its ts field).",
             "The push timestamp is when the event happened, in nanoseconds. Pushed at the time",
             "of shipping, every query for the time of the decline misses it.")

      try:
          ans = open("/obs/answers/ship-one-log-line.txt").read()
      except OSError:
          ans = ""
      def field(name):
          m = re.search(rf"^\s*{name}\s*:(.*)$", ans, re.M | re.I)
          return None if m is None else {w.lower() for w in re.findall(r"[A-Za-z_]+", m.group(1))}
      said_labels, said_line = field("labels"), field("line")
      if said_labels is None or said_line is None:
          no("/obs/answers/ship-one-log-line.txt needs two lines, `labels:` and `line:`, each naming",
             "the record's fields that ended up there.")
      if said_labels != set(labels):
          no(f"the answer says the labels are {', '.join(sorted(said_labels)) or 'nothing'}; the stream in Loki is",
             f"labelled {', '.join(sorted(labels))}.")
      if "order_id" not in said_line:
          no("the answer's `line:` does not mention order_id. Where did it end up?")
      print(f"PASS — {oid} is in Loki at the time it happened, in the stream {show(labels)},")
      print(f"and `{q}` finds it.")
      PY
