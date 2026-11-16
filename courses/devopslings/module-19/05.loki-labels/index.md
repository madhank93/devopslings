---
kind: lesson
title: "Looking up one failed request reads every line shop logged"
description: |
  Support sends a request id and "payments returned a 500". Finding that one
  line in Loki takes long enough that people give up and grep the hosts.
  The obvious fix is to make the request id a label. Make the lookup read a
  small slice of the logs instead, without giving Loki a stream per request.
name: loki-labels
slug: loki-labels
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
      cat > /obs/vector/ship.yaml <<'YML'
      # How shop's logs reach Loki. A stdin source named `shop` feeds this file
      # (see `shop-logs ship`); every line is one JSON object.
      transforms:
        parse:
          type: remap
          inputs: [shop]
          source: |
            . = merge!(., parse_json!(.message))

      sinks:
        loki:
          type: loki
          inputs: [parse]
          endpoint: http://loki:3100
          encoding:
            codec: text          # the line Loki stores is the original .message
          labels:
            app: shop
      YML
      printf '%s\n' '{app="shop"} |= "${request_id}"' > /obs/queries/lookup.logql
      shop-logs ship 6000 >/obs/run/loki-labels.sample 2>/dev/null
      echo "scenario ready: shop's logs ship to Loki through Vector with /obs/vector/ship.yaml."
      echo "Support's lookup is in /obs/queries/lookup.logql. 'shop-logs ship' sends a fresh"
      echo "batch with your config; $(cut -d';' -f2 /obs/run/loki-labels.sample | sed 's/^ //')"

  verify_done:
    timeout_seconds: 120
    run: |
      . /usr/local/lib/obs.sh
      python3 - <<'PY'
      import json, re, subprocess, sys, time, urllib.parse, urllib.request

      LOKI, N = "http://loki:3100", 6000
      BUDGET = N // 100  # lines a lookup may read
      MAX_VALUES, MAX_STREAMS = 20, 100

      def no(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print(l)
          sys.exit(1)

      def get(path, **params):
          try:
              with urllib.request.urlopen(f"{LOKI}{path}?{urllib.parse.urlencode(params)}", timeout=20) as r:
                  return json.load(r), None
          except urllib.error.HTTPError as e:
              return None, e.read().decode(errors="replace").strip()

      try:
          q = open("/obs/queries/lookup.logql").read().strip()
      except OSError:
          q = ""
      if "${request_id}" not in q:
          no("/obs/queries/lookup.logql has no ${request_id} in it. The check fills in real request",
             "ids there, so the file is the lookup support would run for any request.")

      # A fresh batch through the student's shipping config, in its own slice of
      # time: the pause keeps a batch shipped just before out of the window.
      time.sleep(1.5)
      t0 = time.time_ns() - 10**9
      p = subprocess.run(["shop-logs", "ship", str(N), "/tmp/loki-labels.sent"], capture_output=True, text=True)
      time.sleep(1)
      t1 = time.time_ns() + 10**9
      if p.returncode != 0:
          no("Vector could not ship with /obs/vector/ship.yaml:",
             *["  " + l for l in p.stderr.strip().splitlines()[-6:]])
      sent = [json.loads(l) for l in open("/tmp/loki-labels.sent")]
      win = dict(start=t0, end=t1)

      def too_many(name, count):
          no(f"the label {name} had {count} different values in one batch of {N} lines. Each value is",
             "a stream of its own: Loki indexes, stores and lists it separately, and a stream with",
             "a line or two in it compresses to nothing. Anything with that many values belongs in",
             "the line, where |= finds it.")

      # Every stream in the batch, with its line count. The labels API is only
      # day-accurate, so label names come from it and streams from a query over
      # exactly this batch's time.
      names = (get("/loki/api/v1/labels", **win)[0] or {}).get("data", [])
      span = f"[{(t1 - t0) // 10**6}ms]"
      def scalar(expr):
          res, _ = get("/loki/api/v1/query", query=expr, time=t1)
          r = (res or {}).get("data", {}).get("result") or [{"value": [0, 0]}]
          return int(float(r[0]["value"][1]))
      # Distinct values per label in this batch. The labels API is only
      # day-accurate, so names come from it and counts from exact-time queries.
      counts = {n: scalar(f'count(sum by ({n}) (count_over_time({{{n}=~".+"}}{span})))') for n in names}
      big = sorted(((c, n) for n, c in counts.items() if c > MAX_VALUES), reverse=True)
      if big:
          count, name = big[0]
          no(f"the label {name} had {count} different values in one batch of {N} lines. Each value is",
             "a stream of its own: Loki indexes, stores and lists it separately, and a stream with",
             "a line or two in it compresses to nothing. Anything with that many values belongs in",
             "the line, where |= finds it.")
      streams = {}
      for n in names:
          res, _ = get("/loki/api/v1/query", query=f'count_over_time({{{n}=~".+"}}{span})', time=t1)
          for s in (res or {}).get("data", {}).get("result", []):
              streams[json.dumps(s["metric"], sort_keys=True)] = int(s["value"][1])
      got = sum(streams.values())
      if len(streams) > MAX_STREAMS:
          no(f"one batch of {N} lines made {len(streams)} streams. Labels: {', '.join(names)}.",
             "Every combination of label values is a stream; keep the combinations few.")
      if got < N:
          no(f"Loki received {got} of the {N} lines shop-logs sent. The shipper has to deliver every",
             "line; making the lookup cheap by dropping logs makes the next lookup impossible.",
             *["  " + l for l in p.stderr.strip().splitlines()[-3:]])

      # What a lookup costs: every line, in this batch, of the streams its
      # selector picks. Loki reads all of them to apply the line filter. Counted
      # from the batch rather than from Loki's query statistics, which include
      # earlier batches that share a chunk.
      m = re.match(r'\s*\{(?:[^}"`]|"(?:\\.|[^"\\])*"|`[^`]*`)*\}', q)
      if not m:
          no("/obs/queries/lookup.logql does not start with a stream selector:", f"  {q}")
      res, err = get("/loki/api/v1/query", query=f"sum(count_over_time({m.group(0)}{span}))", time=t1)
      if err:
          no("Loki rejected the lookup's stream selector:", f"  {m.group(0)}", f"  {err}")
      read = int(float(((res or {}).get("data", {}).get("result") or [{"value": [0, 0]}])[0]["value"][1]))

      targets = [r for r in sent if r["service"] == "payments" and r["level"] == "error"][:3]
      for r in targets:
          lq = q.replace("${request_id}", r["request_id"])
          res, err = get("/loki/api/v1/query_range", query=lq, limit=100, **win)
          if err:
              no("Loki rejected the lookup:", f"  {lq}", f"  {err}")
          lines = [l for s in res["data"]["result"] for _, l in s["values"]]
          if not any(r["request_id"] in l for l in lines):
              shown = sorted(streams, key=streams.get, reverse=True)[:4]
              no(f"the lookup did not find {r['request_id']}, a payments error in this batch:", f"  {lq}",
                 "The batch went to these streams (the largest four):",
                 *[f"  {json.loads(s)}  {streams[s]} lines" for s in shown])
          if len(lines) != 1:
              no(f"the lookup returned {len(lines)} lines for one request:", f"  {lq}",
                 "Pick the streams with the selector, then the request with a line filter.")

      if read > BUDGET:
          picked = sorted({k for s in streams for k in json.loads(s)})
          no(f"the lookup's selector {m.group(0)} picks streams holding {read} of the batch's {N}",
             f"lines ({read * 100 // N}%), and Loki reads every one of them to find one request. The",
             f"budget is {BUDGET}. The ticket says which service failed and that it was an error;",
             f"your streams are labelled by {', '.join(picked)}.")
      worst = read
      print(f"PASS — {len(streams)} streams for {N} lines, and a lookup reads at most {worst} lines")
      print(f"({worst * 100 / N:.1f}%) to find the one it wants.")
      PY
