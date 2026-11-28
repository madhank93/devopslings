---
kind: lesson
title: "The customer's failed checkout is in no trace"
description: |
  checkout keeps one trace in a hundred to stay inside the storage budget.
  A customer reports a failed order, and the trace that would explain it was
  never kept; neither were most of the slow ones. Keep every error and every
  slow trace, and still store about one in a hundred of the rest.
name: head-sampling-hides-errors
slug: head-sampling-hides-errors
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
      cat > /obs/apps/checkout.py <<'PY'
      """checkout — POST /checkout on :8080 places an order and records it with
      ledger. A body with "card": "declined" fails with a 500; "slow": true
      takes a slow payment path. Customers are simulated in-process, about 25
      orders a second; GET /stats counts the orders placed.

      Tracing costs money, so checkout decides at the start of each request
      to keep one trace in a hundred.
      """
      import json
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
      from opentelemetry.sdk.trace.sampling import ParentBased, TraceIdRatioBased
      from opentelemetry.trace import Status, StatusCode

      provider = TracerProvider(resource=Resource.create({"service.name": "checkout"}),
                                sampler=ParentBased(TraceIdRatioBased(0.01)))
      provider.add_span_processor(BatchSpanProcessor(
          OTLPSpanExporter(endpoint="http://collector:4318/v1/traces"),
          schedule_delay_millis=500, max_queue_size=20000))
      trace.set_tracer_provider(provider)
      tracer = trace.get_tracer("checkout")
      placed = {"orders": 0}
      lock = threading.Lock()


      class Declined(Exception):
          pass


      def place(order):
          with tracer.start_as_current_span("POST /checkout", kind=trace.SpanKind.SERVER) as span:
              span.set_attribute("order.id", order["order_id"])
              time.sleep(random.uniform(0.005, 0.02))
              if order.get("slow"):
                  time.sleep(0.6)
              with tracer.start_as_current_span("POST /entries", kind=trace.SpanKind.CLIENT):
                  headers = {"Content-Type": "application/json"}
                  propagate.inject(headers)
                  urllib.request.urlopen(urllib.request.Request(
                      "http://ledger:8080/entries", data=json.dumps(order).encode(), headers=headers),
                      timeout=3).read()
              if order.get("card") == "declined":
                  e = Declined(f"card declined for order {order['order_id']}")
                  span.record_exception(e)
                  span.set_status(Status(StatusCode.ERROR, str(e)))
                  raise e


      class Handler(BaseHTTPRequestHandler):
          def log_message(self, *a):
              pass

          def reply(self, code, body=b""):
              self.send_response(code)
              self.send_header("Content-Length", str(len(body)))
              self.end_headers()
              self.wfile.write(body)

          def do_GET(self):
              if self.path == "/stats":
                  return self.reply(200, json.dumps(placed).encode())
              self.reply(404)

          def do_POST(self):
              order = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0) or 0)) or b"{}")
              with lock:
                  placed["orders"] += 1
              try:
                  place(order)
                  self.reply(201)
              except Declined:
                  self.reply(500, b"card declined")
              except Exception as e:
                  print(f"order {order.get('order_id')} failed: {e}", flush=True)
                  self.reply(502)


      def customers():
          n = int(time.time()) % 100000 * 1000
          while True:
              n += 1
              order = {"order_id": f"ord-{n}"}
              if random.random() < 0.01:
                  order["card"] = "declined"
              try:
                  urllib.request.urlopen(urllib.request.Request(
                      "http://localhost:8080/checkout", data=json.dumps(order).encode(),
                      headers={"Content-Type": "application/json"}), timeout=5).read()
              except OSError:
                  pass
              time.sleep(0.03)


      threading.Thread(target=customers, daemon=True).start()
      ThreadingHTTPServer.daemon_threads = True
      ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
      PY
      cat > /obs/apps/ledger.py <<'PY'
      """ledger — records orders. POST /entries on :8080. Its sampler follows
      the caller's decision. Storage faults for given orders come from
      /obs/run/ledger.faults, one "<order id> fail|stall" per line.
      """
      import json
      import time
      from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

      from opentelemetry import propagate, trace
      from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
      from opentelemetry.sdk.resources import Resource
      from opentelemetry.sdk.trace import TracerProvider
      from opentelemetry.sdk.trace.export import BatchSpanProcessor
      from opentelemetry.trace import Status, StatusCode

      provider = TracerProvider(resource=Resource.create({"service.name": "ledger"}))
      provider.add_span_processor(BatchSpanProcessor(
          OTLPSpanExporter(endpoint="http://collector:4318/v1/traces"),
          schedule_delay_millis=500, max_queue_size=20000))
      trace.set_tracer_provider(provider)
      tracer = trace.get_tracer("ledger")


      def fault(order_id):
          try:
              for line in open("/obs/run/ledger.faults"):
                  oid, kind = line.split()
                  if oid == order_id:
                      return kind
          except (OSError, ValueError):
              pass
          return None


      class Handler(BaseHTTPRequestHandler):
          def log_message(self, *a):
              pass

          def do_POST(self):
              try:
                  order_id = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0) or 0)))["order_id"]
              except (ValueError, KeyError, TypeError):
                  order_id = None
              f = fault(order_id)
              with tracer.start_as_current_span("POST /entries", context=propagate.extract(self.headers),
                                                kind=trace.SpanKind.SERVER) as span:
                  time.sleep(0.003)
                  if f == "stall":
                      time.sleep(0.6)
                  if f == "fail":
                      span.set_status(Status(StatusCode.ERROR, "write failed"))
              self.send_response(500 if f == "fail" else 201)
              self.send_header("Content-Length", "0")
              self.end_headers()


      ThreadingHTTPServer.daemon_threads = True
      ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
      PY
      for a in ledger checkout; do app_restart "$a"; app_up "$a"; done
      echo "scenario ready: checkout places ~25 orders a second, about 1% of them declined (HTTP 500),"
      echo "and keeps one trace in a hundred. Spans go through the Collector (/obs/otel/collector.yaml)."
      echo "Traces of failed orders in Tempo:"
      echo "  curl -s 'http://tempo:3200/api/search?q={status=error}&limit=20' | jq '.traces | length'"
      echo "Source: /obs/apps/checkout.py."

  verify_done:
    timeout_seconds: 240
    run: |
      . /usr/local/lib/obs.sh
      collector_settle || exit 1
      python3 - <<'PY'
      import json, os, random, re, sys, time, urllib.error, urllib.parse, urllib.request

      TEMPO = "http://tempo:3200"
      BUDGET = 0.05   # stored traces, as a share of all orders
      ERRORS, SLOW = 8, 5

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

      def get(url):
          with urllib.request.urlopen(url, timeout=10) as r:
              return json.load(r)

      def orders():
          try:
              return get("http://checkout:8080/stats")["orders"]
          except (OSError, ValueError, KeyError) as e:
              no(f"checkout did not answer GET /stats ({e}). The end of /obs/logs/checkout.log:", *tail("checkout"))

      def lesson_error(*lines):
          print("lesson error: " + lines[0])
          for l in lines[1:]:
              print(l)
          sys.exit(1)

      def accepted():
          try:
              with urllib.request.urlopen("http://collector:8888/metrics", timeout=10) as r:
                  vals = [float(m.group(1)) for m in re.finditer(
                      r'^otelcol_receiver_accepted_spans_total(?:\{[^}]*\})?\s+(\S+)',
                      r.read().decode(), re.M)]
          except OSError as e:
              lesson_error(f"the Collector's metrics on :8888 did not answer ({e}). The end of",
                           "/obs/logs/collector.log:", *tail("collector"))
          # The series appears with the first span the receiver accepts.
          return sum(vals) if vals else None

      def started(app):
          try:
              return int(open(f"/obs/run/{app}.started").read())
          except (OSError, ValueError):
              return 0

      # supervise restarts an edited app within half a second; until then
      # .started still holds the previous start.
      time.sleep(1)
      time.sleep(max(0, max(started(a) for a in ("checkout", "ledger", "collector")) + 4 - time.time()))
      # Probe ids look like the customers' order ids, so nothing but the
      # outcome sets them apart.
      ID = {i: f"ord-{n}" for i, n in enumerate(random.sample(range(10**7, 10**8), ERRORS + SLOW))}
      start, n0, s0 = int(time.time()), orders(), accepted() or 0.0

      def place(i, **kw):
          body = json.dumps(dict(order_id=ID[i], **kw)).encode()
          try:
              urllib.request.urlopen(urllib.request.Request("http://checkout:8080/checkout", data=body,
                                                            headers={"Content-Type": "application/json"}), timeout=10).read()
          except urllib.error.HTTPError:
              pass
          except OSError as e:
              no(f"checkout did not answer ({e}). The end of /obs/logs/checkout.log:", *tail("checkout"))

      # Half the probes carry their outcome in the body; ledger fails or stalls
      # the rest, which nothing knows when the request starts.
      HIDDEN = {i: ("fail" if i < ERRORS else "stall") for i in range(ERRORS + SLOW)
                if (i < ERRORS and i % 2) or i >= ERRORS + 2}
      FAULTS = "/obs/run/ledger.faults"
      with open(FAULTS, "w") as f:
          f.writelines(f"{ID[i]} {k}\n" for i, k in HIDDEN.items())
      try:
          for i in range(ERRORS + SLOW):
              if i in HIDDEN:
                  place(i)
              else:
                  place(i, card="declined") if i < ERRORS else place(i, slow=True)
              time.sleep(3)
      finally:
          os.remove(FAULTS)
      end, n1, s1 = int(time.time()), orders(), accepted()
      placed = n1 - n0

      def search(q, limit=3000):
          p = urllib.parse.urlencode({"q": q, "start": start - 1, "end": end + 2, "limit": limit, "spss": 1})
          try:
              return get(f"{TEMPO}/api/search?{p}").get("traces", [])
          except (OSError, ValueError) as e:
              no(f"Tempo did not answer a search ({e}).")

      def probes():
          found = set()
          index = {v: i for i, v in ID.items()}
          for t in search(f'{{span.order.id=~"{"|".join(ID.values())}"}}', 100):
              for ss in t.get("spanSets", []) or [t.get("spanSet", {})]:
                  for s in ss.get("spans", []):
                      for a in s.get("attributes", []):
                          if a["key"] == "order.id":
                              if a["value"].get("stringValue") in index:
                                  found.add(index[a["value"]["stringValue"]])
          return found

      # Tail sampling holds each trace for its decision_wait before it reaches Tempo.
      deadline = time.time() + 90
      while True:
          got = probes()
          if len(got) == ERRORS + SLOW or time.time() > deadline:
              break
          time.sleep(5)
      time.sleep(5)

      errs = [i for i in range(ERRORS) if i not in got]
      slow = [i for i in range(ERRORS, ERRORS + SLOW) if i not in got]
      if s1 is None:
          if search('{resource.service.name="checkout"}', 1):
              lesson_error("the Collector's metrics on :8888 have no otelcol_receiver_accepted_spans_total series,",
                           "though spans reach Tempo, so the check cannot count the spans it receives. Keep the",
                           "Collector's own telemetry on :8888 as it was.")
          s1 = 0.0
      if s1 < s0:
          lesson_error(f"the Collector's accepted-spans counter went down ({s0:.0f} to {s1:.0f}) while the check",
                       "ran: the Collector restarted mid-run. Run the check again once it stays up.")
      sent = (s1 - s0) / max(placed, 1)
      missed = errs + slow
      if missed and sent < 1.0 and all(i in HIDDEN for i in missed):
          no(f"{len(missed)} of the orders ledger failed or stalled are in no trace (order {ID[missed[0]]}),",
             "while every order whose body said 'declined' or 'slow' is: checkout keeps a trace by what",
             "the request says when it starts, and a failure further down says nothing there. The",
             f"Collector received {sent:.2f} spans per order, where a whole order is three.")
      if errs:
          if sent < 1.0:
              no(f"{len(errs)} of the {ERRORS} declined orders the check placed are in no trace (order",
                 f"{ID[errs[0]]}). The Collector received {sent:.2f} spans per order, where a whole",
                 "order is three: checkout still drops most traces when the request starts, before anyone",
                 "knows it will fail, and nothing downstream can keep what was never sent.")
          no(f"{len(errs)} of the {ERRORS} declined orders the check placed are in no trace (order",
             f"{ID[errs[0]]}), although every span reached the Collector. Its traces pipeline",
             "has to keep every trace with an error in it.")
      if slow:
          if sent < 1.0:
              no(f"{len(slow)} of the {SLOW} orders the check made take 600ms are in no trace (order",
                 f"{ID[slow[0]]}). The Collector received {sent:.2f} spans per order, where a whole",
                 "order is three: checkout drops most traces when the request starts, before anyone knows",
                 "it will be slow.")
          no(f"{len(slow)} of the {SLOW} orders the check made take 600ms are in no trace (order",
             f"{ID[slow[0]]}). Every trace over 500ms has to be kept.")

      kept = search('{resource.service.name="checkout" && name="POST /checkout"}')
      ours = [t for t in kept if t.get("durationMs", 0) < 500]
      share = (len(kept) - ERRORS - SLOW) / max(placed - ERRORS - SLOW, 1)
      if len(kept) >= 3000 or share > BUDGET:
          no(f"Tempo stored {len(kept)}{'+' if len(kept) >= 3000 else ''} checkout traces for the {placed} orders placed",
             f"while the check ran: {share:.0%} of the customers' orders. The budget is {BUDGET:.0%}: errors,",
             "slow traces, and about 1% of the rest.")
      err_ids = {t["traceID"] for t in search('{resource.service.name="checkout" && status=error}')}
      rest = sum(1 for t in ours if t["traceID"] not in err_ids)
      if rest < 1:
          no(f"of the {placed} orders placed while the check ran, Tempo kept the errors and the slow",
             "ones and none of the rest. A baseline of ordinary traces is what tells you what normal",
             "looks like; keep about 1% of them.")
      print(f"PASS — every declined and every slow order the check placed is in Tempo, and {len(kept)} traces")
      print(f"were stored for {placed} orders ({share:.1%}), {rest} of them ordinary.")
      PY
---
