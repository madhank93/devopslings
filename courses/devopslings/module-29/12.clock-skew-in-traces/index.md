---
kind: lesson
title: "ledger answers seconds before checkout asks"
description: |
  In every checkout trace, ledger's span starts seconds before the call that
  caused it, and ends before it starts. fulfil's span, in the same trace,
  sits where it should. Find the cause, measure it, and fix it where it
  lives.
name: clock-skew-in-traces
slug: clock-skew-in-traces
createdAt: "2026-11-23"

sandbox:
  stack: obs-stack
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 240
    run: |
      obs-reset >/dev/null
      mkdir -p /obs/data
      . /usr/local/lib/obs.sh
      mkdir -p /obs/hosts/checkout /obs/hosts/ledger /obs/hosts/fulfil /obs/data
      cat /proc/sys/kernel/random/uuid > /obs/hosts/ledger/unsynced
      cat > /obs/apps/svc.py <<'PY'
      """A small traced HTTP service: serve(name, work, calls) answers POST on
      :8080, spends `work` seconds in a child span, then calls each URL in
      `calls` in turn. Spans go to the Collector over OTLP/HTTP.
      """
      import json
      import os
      import random
      import threading
      import time
      import urllib.request
      from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

      from opentelemetry import propagate, trace
      from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
      from opentelemetry.sdk.resources import Resource
      from opentelemetry.sdk.trace import TracerProvider
      from opentelemetry.sdk.trace.export import BatchSpanProcessor

      import hostclock


      def unsynced_clock(host):
          """Emulates a host whose time sync broke. While /obs/hosts/<host>/unsynced
          exists, the host's wall clock is off by a few seconds. The offset lives on
          the host alone (its own /tmp), so it survives restarts and nothing outside
          the host can read it. Touching /obs/hosts/<host>/makestep steps the clock
          back, as `chronyc makestep` does; removing `unsynced` resyncs it too.
          """
          flag, step, local = f"/obs/hosts/{host}/unsynced", f"/obs/hosts/{host}/makestep", "/tmp/clock-offset"
          try:
              incident = open(flag).read().strip()
          except OSError:
              return
          try:
              seen = open(local).read().split()[1]
          except (OSError, IndexError):
              seen = None
          if seen != incident:
              with open(local, "w") as f:
                  f.write(f"-{random.uniform(2.2, 4.8):.3f} {incident}\n")
          hostclock._path = local
          hostclock._state["checked"] = -2.0

          def watch():
              while True:
                  if os.path.exists(step) or not os.path.exists(flag):
                      with open(local, "w") as f:
                          f.write(f"0 {incident}\n")
                      return
                  time.sleep(0.5)

          threading.Thread(target=watch, daemon=True).start()


      def serve(name, route, work, calls=(), customers=False):
          unsynced_clock(name)
          provider = TracerProvider(resource=Resource.create({"service.name": name}))
          provider.add_span_processor(BatchSpanProcessor(
              OTLPSpanExporter(endpoint="http://collector:4318/v1/traces"), schedule_delay_millis=500))
          trace.set_tracer_provider(provider)
          tracer = trace.get_tracer(name)

          class Handler(BaseHTTPRequestHandler):
              def log_message(self, *a):
                  pass

              def do_POST(self):
                  self.rfile.read(int(self.headers.get("Content-Length", 0) or 0))
                  with tracer.start_as_current_span(f"POST {route}", context=propagate.extract(self.headers),
                                                    kind=trace.SpanKind.SERVER):
                      with tracer.start_as_current_span(work[0]):
                          time.sleep(work[1])
                      for url in calls:
                          with tracer.start_as_current_span("POST " + url.split(":8080")[1],
                                                            kind=trace.SpanKind.CLIENT):
                              headers = {"Content-Type": "application/json"}
                              propagate.inject(headers)
                              urllib.request.urlopen(urllib.request.Request(url, data=b"{}", headers=headers),
                                                     timeout=5).read()
                  self.send_response(201)
                  self.send_header("Content-Length", "0")
                  self.end_headers()

          def shoppers():
              while True:
                  try:
                      urllib.request.urlopen(urllib.request.Request(f"http://localhost:8080{route}", data=b"{}"),
                                             timeout=5).read()
                  except OSError:
                      pass
                  time.sleep(random.uniform(0.5, 1.0))

          if customers:
              threading.Thread(target=shoppers, daemon=True).start()
          ThreadingHTTPServer.daemon_threads = True
          ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
      PY
      cat > /obs/apps/checkout.py <<'PY'
      """checkout — takes orders, records each with ledger and ships it with fulfil."""
      from svc import serve
      serve("checkout", "/checkout", ("validate cart", 0.01),
            ["http://ledger:8080/entries", "http://fulfil:8080/shipments"], customers=True)
      PY
      cat > /obs/apps/ledger.py <<'PY'
      """ledger — records orders."""
      from svc import serve
      serve("ledger", "/entries", ("INSERT entries", 0.02))
      PY
      cat > /obs/apps/fulfil.py <<'PY'
      """fulfil — books shipments."""
      from svc import serve
      serve("fulfil", "/shipments", ("book carrier", 0.03))
      PY
      cat > /obs/answers/clock-skew.txt <<'TXT'
      # '#' starts a comment.
      cause: ?       # what makes these spans start before their parent, in a few words
      host: ?        # the host it is on
      offset_ms: ?   # how far off, in milliseconds, as you measured it from a trace
      TXT
      for a in ledger fulfil checkout; do app_restart "$a"; app_up "$a"; done
      # The check reads the real offset from this first trace. Spans sent while
      # the Collector is still starting can be lost, so retry until Tempo has
      # ledger's span under checkout's.
      python3 - <<'PY'
      import json, os, sys, time, urllib.request
      for attempt in range(6):
          tid = os.urandom(16).hex()
          try:
              urllib.request.urlopen(urllib.request.Request("http://checkout:8080/checkout", data=b"{}", headers={
                  "traceparent": f"00-{tid}-{os.urandom(8).hex()}-01"}), timeout=10).read()
          except OSError:
              time.sleep(2)
              continue
          for _ in range(10):
              time.sleep(2)
              try:
                  with urllib.request.urlopen(f"http://tempo:3200/api/traces/{tid}", timeout=10) as r:
                      batches = json.load(r).get("batches", [])
              except (OSError, ValueError):
                  continue
              spans = {}
              for b in batches:
                  svc = next((a["value"].get("stringValue") for a in b.get("resource", {}).get("attributes", [])
                              if a["key"] == "service.name"), "?")
                  for ss in b.get("scopeSpans", []):
                      for sp in ss.get("spans", []):
                          spans[sp["spanId"]] = (svc, sp.get("parentSpanId"))
              # The same link the check measures: a ledger span whose parent is checkout's.
              if any(svc == "ledger" and spans.get(parent, ("",))[0] == "checkout" for svc, parent in spans.values()):
                  open("/obs/data/clock-skew.trace", "w").write(tid + "\n")
                  sys.exit(0)
      sys.exit("no complete trace of POST /checkout reached Tempo")
      PY
      echo "scenario ready: checkout takes an order every second or so, calls ledger, then fulfil."
      echo "Each app runs on a host of its own name. Spans go through the Collector to Tempo."
      echo "  curl -s 'http://tempo:3200/api/search?q={name=\"POST /checkout\"}&limit=3' | jq -r '.traces[].traceID'"
      echo "Your answer: /obs/answers/clock-skew.txt"

  verify_done:
    timeout_seconds: 120
    run: |
      python3 - <<'PY'
      import json, os, re, sys, time, urllib.error, urllib.request

      TEMPO = "http://tempo:3200"
      ANSWER = "/obs/answers/clock-skew.txt"
      HOSTS = ("checkout", "ledger", "fulfil")
      BOUND_MS = 1.0

      def no(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print(l)
          sys.exit(1)

      def tail(app):
          try:
              return ["  " + l.rstrip()[:200] for l in open(f"/obs/logs/{app}.log").readlines()[-3:]]
          except OSError:
              return []

      def trace_spans(tid):
          spans = []
          try:
              with urllib.request.urlopen(f"{TEMPO}/api/traces/{tid}", timeout=10) as r:
                  for b in json.load(r).get("batches", []):
                      svc = next((a["value"].get("stringValue") for a in b.get("resource", {}).get("attributes", [])
                                  if a["key"] == "service.name"), "?")
                      spans += [dict(s, svc=svc) for ss in b.get("scopeSpans", []) for s in ss.get("spans", [])]
          except urllib.error.HTTPError as e:
              if e.code != 404:
                  no(f"Tempo answered {e.code} for trace {tid}.")
          except OSError as e:
              no(f"Tempo did not answer ({e}).")
          return spans

      # The real offset is the skew in the trace the lesson sent at its start.
      try:
          first = open("/obs/data/clock-skew.trace").read().strip()
      except OSError:
          print("lesson error: /obs/data/clock-skew.trace is gone. Your answer was not graded; reset the lesson.")
          sys.exit(1)
      deadline = time.time() + 25
      while True:
          spans = trace_spans(first)
          by_id = {s["spanId"]: s for s in spans}
          skews = [(int(s["startTimeUnixNano"]) - int(by_id[s["parentSpanId"]]["startTimeUnixNano"])) / 1e6
                   for s in spans if s["svc"] == "ledger" and by_id.get(s.get("parentSpanId"), {}).get("svc") == "checkout"]
          if skews or time.time() > deadline:
              break
          time.sleep(2)
      if not skews:
          print(f"lesson error: Tempo no longer has the trace this lesson recorded at its start ({first}),")
          print("so the real offset cannot be read. Your answer was not graded; reset the lesson.")
          sys.exit(1)
      truth = abs(skews[0])

      def field(name):
          try:
              for line in open(ANSWER):
                  m = re.match(rf"\s*{name}\s*:\s*(.*)", line)
                  if m:
                      return re.sub(r"\s+#.*$", "", m.group(1)).strip()
          except OSError:
              no(f"{ANSWER} is missing. Reset the lesson to get the template back.")
          return ""

      cause, host, off = field("cause"), field("host").lower(), field("offset_ms")
      for k, v in (("cause", cause), ("host", host), ("offset_ms", off)):
          if not v or v == "?":
              no(f"{k} in {ANSWER} is not filled in.")
      if re.search(r"time ?zone|\btz\b|collector", cause.lower()) or not re.search(
              r"\b(clocks?|ntpd?|chronyd?|skew(ed)?|drift(ed|ing)?|time[ _-]?sync)\b", cause.lower()):
          no(f"cause is '{cause}'. Spans from one service sit where they should in the same trace, so",
             "context propagation and the span code work. What differs between the hosts?")
      if host != "ledger":
          no(f"host is '{host}'. Which service's spans are out of place against their parent, and which",
             "are not?")
      try:
          measured = abs(float(off.lower().removesuffix("ms").strip()))
      except ValueError:
          no(f"offset_ms in {ANSWER} is '{off}'; write a number of milliseconds.")
      if abs(measured - truth) > 150:
          if abs(measured * 1000 - truth) <= 150:
              no(f"offset_ms is {off}. That looks like seconds; the field is in milliseconds.")
          no(f"offset_ms is {off}. Compare when ledger's server span starts with when checkout's client",
             "span that called it starts, in a trace from before the fix.")

      for h in HOSTS:
          try:
              v = float(open(f"/obs/hosts/{h}/clock-offset").read().split()[0]) * 1000
          except (OSError, ValueError, IndexError):
              v = 0.0
          if abs(v) >= BOUND_MS and h == "ledger":
              no(f"/obs/hosts/ledger/clock-offset holds {v:+.0f}ms. Adding a second offset on top of a",
                 "wrong clock does not fix it: step ledger's clock (/obs/hosts/ledger/makestep) and put",
                 "that file back to 0.")
          if abs(v) >= BOUND_MS:
              no(f"{h}'s host clock is now {v:+.0f}ms off (/obs/hosts/{h}/clock-offset). Moving hosts to",
                 "agree with ledger makes the spans nest and every one of those clocks wrong. Put it back to 0.")
      if os.path.exists("/obs/hosts/ledger/unsynced") and not os.path.exists("/obs/hosts/ledger/makestep"):
          no("ledger's host clock has not been stepped. Whatever the traces show, every timestamp that",
             "host writes — logs, tokens, certificates, span times — is still wrong.")

      def started(app):
          try:
              return int(open(f"/obs/run/{app}.started").read())
          except (OSError, ValueError):
              return 0

      # supervise restarts an edited app within half a second; until then
      # .started still holds the previous start. A stepped clock reaches the
      # app within 1.5s.
      time.sleep(2)
      time.sleep(max(0, max(started(a) for a in HOSTS + ("collector",)) + 3 - time.time()))
      tid = os.urandom(16).hex()
      try:
          urllib.request.urlopen(urllib.request.Request("http://checkout:8080/checkout", data=b"{}", headers={
              "traceparent": f"00-{tid}-{os.urandom(8).hex()}-01"}), timeout=10).read()
      except OSError as e:
          no(f"POST /checkout failed ({e}). The end of /obs/logs/checkout.log:", *tail("checkout"))

      deadline = time.time() + 25
      while True:
          spans = trace_spans(tid)
          if {s["svc"] for s in spans} >= set(HOSTS) or time.time() > deadline:
              break
          time.sleep(2)
      have = {s["svc"] for s in spans}
      if not have >= set(HOSTS):
          no(f"trace {tid} has spans from {sorted(have) or 'no service'} after 25s; it should have checkout,",
             "ledger and fulfil. Are they running, and is the Collector passing spans to Tempo? The end",
             "of /obs/logs/collector.log:", *tail("collector"))
      by_id = {s["spanId"]: s for s in spans}
      for s in spans:
          p = by_id.get(s.get("parentSpanId"))
          if not p or p["svc"] == s["svc"]:
              continue
          ps, pe = int(p["startTimeUnixNano"]) / 1e6, int(p["endTimeUnixNano"]) / 1e6
          cs, ce = int(s["startTimeUnixNano"]) / 1e6, int(s["endTimeUnixNano"]) / 1e6
          if cs < ps - BOUND_MS or ce > pe + BOUND_MS:
              no(f"in trace {tid}, {s['svc']}'s '{s['name']}' runs {cs - ps:+.1f}ms to {ce - pe:+.1f}ms against",
                 f"its parent, {p['svc']}'s '{p['name']}'. With every host clock right, a child sits inside",
                 "its parent; is something rewriting span times on the way to Tempo?")
      print(f"PASS — ledger's clock was {truth:.0f}ms behind and is now right; in a fresh trace every")
      print("cross-host child span sits inside its parent.")
      PY
---
