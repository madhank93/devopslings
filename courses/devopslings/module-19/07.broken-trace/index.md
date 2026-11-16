---
kind: lesson
title: "Every order's trace stops at the queue"
description: |
  checkout, fulfil and ledger are all instrumented, and every one of them
  sends spans to Tempo. An order still shows up as two traces: checkout's,
  which ends when it publishes to the queue, and fulfil's, which starts from
  nowhere. Make one order one trace, from checkout through the queue to the
  ledger.
name: broken-trace
slug: broken-trace
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
      . /usr/local/lib/obs.sh
      for a in broker ledger fulfil checkout; do app_up "$a"; done
      echo "scenario ready: checkout takes an order every ~300ms and publishes it to broker;"
      echo "fulfil consumes it and records it with ledger. All three send spans to Tempo."
      echo "Find one in Grafana (Explore > Tempo) or with:"
      echo "  curl -s 'http://tempo:3200/api/search?q={resource.service.name=\"fulfil\"}&limit=3' | jq"

  verify_done:
    timeout_seconds: 120
    run: |
      python3 - <<'PY'
      import json, re, sys, time, urllib.parse, urllib.request

      TEMPO = "http://tempo:3200"

      def no(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print(l)
          sys.exit(1)

      def get(url):
          with urllib.request.urlopen(url, timeout=10) as r:
              return json.load(r)

      def started(app):
          try:
              return int(open(f"/obs/run/{app}.started").read())
          except (OSError, ValueError):
              return 0

      def tail(app):
          try:
              lines = [l.rstrip() for l in open(f"/obs/logs/{app}.log") if not l.startswith("[supervise]")]
          except OSError:
              lines = []
          return ["  " + l[:200] for l in lines[-4:]] or ["  (nothing)"]

      # Traces from orders taken after the last edit to any of the services;
      # supervise restarts an edited app within a second.
      time.sleep(1.5)
      since = max(started(a) for a in ("checkout", "fulfil", "ledger", "broker")) + 2
      time.sleep(max(0, since + 10 - time.time()))
      now = int(time.time()) - 3
      q = urllib.parse.urlencode({"q": '{resource.service.name="fulfil" && name="process orders"}',
                                  "start": since, "end": now, "limit": 20})
      try:
          found = get(f"{TEMPO}/api/search?{q}").get("traces", [])
      except OSError as e:
          no(f"Tempo did not answer a search ({e}).")
      if not found:
          no("fulfil has sent no 'process orders' span to Tempo since it last started. Is it",
             "running, and still consuming? The end of /obs/logs/fulfil.log:", *tail("fulfil"))

      def spans(trace_id):
          t = get(f"{TEMPO}/api/traces/{trace_id}")
          out = []
          for b in t.get("batches") or t.get("resourceSpans") or t.get("trace", {}).get("resourceSpans", []):
              svc = next((a["value"].get("stringValue") for a in b.get("resource", {}).get("attributes", [])
                          if a["key"] == "service.name"), "?")
              for ss in b.get("scopeSpans") or b.get("instrumentationLibrarySpans") or []:
                  for s in ss.get("spans", []):
                      out.append(dict(s, service=svc))
          return out

      def carried():
          """A traceparent from the newest messages on broker, or None."""
          try:
              msgs = get("http://broker:8080/peek")
          except (OSError, ValueError):
              return None
          for m in reversed(msgs):
              hit = re.search(r"00-[0-9a-f]{32}-[0-9a-f]{16}-[0-9a-f]{2}", json.dumps(m))
              if hit:
                  return hit.group(0)
          return None

      checked = 0
      for tr in found[:5]:
          ss = spans(tr["traceID"])
          if not ss:
              continue
          checked += 1
          services = {s["service"] for s in ss}
          ids = {s.get("spanId") for s in ss}
          proc = next((s for s in ss if s["service"] == "fulfil" and s.get("name") == "process orders"), {})
          if "checkout" not in services:
              if proc.get("links"):
                  no("fulfil's 'process orders' span is the root of a trace of its own, with a link",
                     "to checkout's span. A link records that two traces are related; it does not make",
                     "them one. The consumer's span needs checkout's span as its parent.")
              if proc.get("parentSpanId") and proc["parentSpanId"] not in ids:
                  no("fulfil's 'process orders' span has a parent, and that parent never reached Tempo.",
                     "The context in the message names a span checkout did not export: inject it while",
                     "checkout's own span is the current one.")
              tp = carried()
              if not tp:
                  no(f"trace {tr['traceID']} starts at fulfil and has no checkout span",
                     "in it, and none of the last ten messages on broker (GET http://broker:8080/peek)",
                     "carries a traceparent. broker queues the body of a publish and nothing else: a",
                     "header on checkout's request to broker never reaches fulfil.")
              no(f"the messages on broker carry trace context ({tp}),",
                 f"and fulfil's 'process orders' span is still the root of trace {tr['traceID']}.",
                 "fulfil starts its span without the context the message brought.")
          if "ledger" not in services:
              lq = urllib.parse.urlencode({"q": '{resource.service.name="ledger"}', "start": since, "end": now, "limit": 1})
              if get(f"{TEMPO}/api/search?{lq}").get("traces"):
                  no(f"trace {tr['traceID']} has checkout and fulfil in it, and ledger's",
                     "spans are in traces of their own. fulfil injects whatever context is current when",
                     "it calls ledger, so its 'process orders' span has to be the current span then.")
              no(f"trace {tr['traceID']} has checkout and fulfil in it, and ledger has",
                 "sent no spans since fulfil last started. The end of /obs/logs/fulfil.log:", *tail("fulfil"))
      if checked < 3:
          no(f"Tempo returned only {checked} of the traces it found. Give it a few seconds and check again.")
      print(f"PASS — {checked} orders out of {checked} are each one trace: checkout, through broker, to")
      print("fulfil and ledger.")
      PY
---
