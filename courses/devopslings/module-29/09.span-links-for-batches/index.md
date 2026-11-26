---
kind: lesson
title: "Forty-nine orders a batch never reach fulfilment"
description: |
  fulfil takes orders off the queue fifty at a time and processes each batch
  as one span. That span is parented to the first order's trace, so the other
  forty-nine orders' traces end at the queue. Connect the batch to every
  order in it.
name: span-links-for-batches
slug: span-links-for-batches
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
      cat > /obs/apps/otel_setup.py <<'PY'
      """Tracer setup shared by the apps: spans go to Tempo over OTLP/HTTP."""
      from opentelemetry import trace
      from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
      from opentelemetry.sdk.resources import Resource
      from opentelemetry.sdk.trace import TracerProvider
      from opentelemetry.sdk.trace.export import BatchSpanProcessor


      def tracer(service):
          provider = TracerProvider(resource=Resource.create({"service.name": service}))
          provider.add_span_processor(BatchSpanProcessor(
              OTLPSpanExporter(endpoint="http://tempo:4318/v1/traces"),
              schedule_delay_millis=500, max_queue_size=20000))
          trace.set_tracer_provider(provider)
          return trace.get_tracer(service)
      PY
      cat > /obs/apps/checkout.py <<'PY'
      """checkout — takes orders on :8080 (POST /checkout) and publishes each
      one to the queue for fulfil. Some customers are simulated in-process.
      """
      import json
      import random
      import threading
      import time
      import urllib.request
      from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

      from opentelemetry import propagate, trace

      from otel_setup import tracer as make_tracer

      tracer = make_tracer("checkout")


      def take(order, incoming):
          with tracer.start_as_current_span("POST /checkout", context=propagate.extract(incoming),
                                            kind=trace.SpanKind.SERVER) as span:
              span.set_attribute("order.id", order["order_id"])
              time.sleep(0.005)
              with tracer.start_as_current_span("orders publish", kind=trace.SpanKind.PRODUCER) as p:
                  p.set_attribute("messaging.destination.name", "orders")
                  headers = {}
                  propagate.inject(headers)
                  body = json.dumps({"headers": headers, "order": order}).encode()
                  urllib.request.urlopen(urllib.request.Request(
                      "http://broker:8080/publish", data=body, headers={"Content-Type": "application/json"}),
                      timeout=3).read()


      class Handler(BaseHTTPRequestHandler):
          def log_message(self, *a):
              pass

          def do_POST(self):
              order = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0) or 0)) or b"{}")
              try:
                  take(order, self.headers)
                  code = 202
              except Exception as e:
                  print(f"order {order.get('order_id')} failed: {e}", flush=True)
                  code = 502
              self.send_response(code)
              self.send_header("Content-Length", "0")
              self.end_headers()


      def customers():
          n = int(time.time()) % 100000 * 100
          while True:
              n += 1
              body = json.dumps({"order_id": f"ord-{n}"}).encode()
              try:
                  urllib.request.urlopen(urllib.request.Request(
                      "http://localhost:8080/checkout", data=body,
                      headers={"Content-Type": "application/json"}), timeout=5).read()
              except OSError:
                  pass
              time.sleep(random.uniform(0.05, 0.15))


      threading.Thread(target=customers, daemon=True).start()
      ThreadingHTTPServer.daemon_threads = True
      ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
      PY
      cat > /obs/apps/broker.py <<'PY'
      """broker — an in-memory queue on :8080.

        POST /publish        append one message ({"headers": {...}, "order": {...}})
        POST /take?max=N     remove and return up to N messages, oldest first
      """
      import json
      import threading
      from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
      from urllib.parse import parse_qs, urlparse

      queue, lock = [], threading.Lock()


      class Handler(BaseHTTPRequestHandler):
          def log_message(self, *a):
              pass

          def do_POST(self):
              body = self.rfile.read(int(self.headers.get("Content-Length", 0) or 0))
              url = urlparse(self.path)
              out = b""
              with lock:
                  if url.path == "/publish":
                      queue.append(json.loads(body))
                  elif url.path == "/take":
                      n = int(parse_qs(url.query).get("max", ["50"])[0])
                      out = json.dumps(queue[:n]).encode()
                      del queue[:n]
              self.send_response(200)
              self.send_header("Content-Length", str(len(out)))
              self.end_headers()
              self.wfile.write(out)


      ThreadingHTTPServer.daemon_threads = True
      ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
      PY
      cat > /obs/apps/fulfil.py <<'PY'
      """fulfil — ships orders. Every two seconds it takes up to 50 orders off
      the queue and books them with the warehouse in one call.
      """
      import json
      import time
      import urllib.request

      from opentelemetry import propagate, trace

      from otel_setup import tracer as make_tracer

      tracer = make_tracer("fulfil")


      def process(batch):
          # A span has one parent; the first order's will do.
          parent = propagate.extract(batch[0]["headers"])
          with tracer.start_as_current_span("orders process", context=parent,
                                            kind=trace.SpanKind.CONSUMER) as span:
              span.set_attribute("messaging.batch.message_count", len(batch))
              with tracer.start_as_current_span("book shipments"):
                  time.sleep(0.02 + 0.001 * len(batch))


      while True:
          time.sleep(2)
          try:
              with urllib.request.urlopen(urllib.request.Request(
                      "http://broker:8080/take?max=50", data=b"", method="POST"), timeout=3) as r:
                  batch = json.load(r)
          except OSError as e:
              print(f"broker: {e}", flush=True)
              continue
          if batch:
              process(batch)
      PY
      for a in broker fulfil checkout; do app_restart "$a"; app_up "$a"; done
      echo "scenario ready: checkout takes ~10 orders a second and publishes each to broker; fulfil"
      echo "takes up to 50 off the queue every two seconds and processes them as one batch."
      echo "Traces with a fulfil span in them, against all the orders:"
      echo "  curl -s 'http://tempo:3200/api/search?q={resource.service.name=\"fulfil\"}&limit=20' | jq '.traces | length'"
      echo "  curl -s 'http://tempo:3200/api/search?q={name=\"POST /checkout\"}&limit=20' | jq '.traces | length'"
      echo "Source: /obs/apps/fulfil.py (and checkout.py, broker.py, otel_setup.py)."

  verify_done:
    timeout_seconds: 150
    run: |
      python3 - <<'PY'
      import base64, json, os, sys, time, urllib.error, urllib.parse, urllib.request

      TEMPO = "http://tempo:3200"
      N = 60

      def no(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print(l)
          sys.exit(1)

      def get(url):
          with urllib.request.urlopen(url, timeout=10) as r:
              return json.load(r)

      def tail(app):
          try:
              return ["  " + l.rstrip()[:200] for l in open(f"/obs/logs/{app}.log").readlines()[-3:]]
          except OSError:
              return []

      def hexid(v):
          if len(v) in (16, 32) and all(c in "0123456789abcdefABCDEF" for c in v):
              return v.lower()
          return base64.b64decode(v).hex()

      def started(app):
          try:
              return int(open(f"/obs/run/{app}.started").read())
          except (OSError, ValueError):
              return 0

      # supervise restarts an edited app within half a second; until then
      # .started still holds the previous start.
      time.sleep(1)
      time.sleep(max(0, max(started(a) for a in ("checkout", "broker", "fulfil")) + 3 - time.time()))
      since = int(time.time()) - 1

      probes = {}
      for i in range(N):
          tid = os.urandom(16).hex()
          req = urllib.request.Request("http://checkout:8080/checkout",
                                       data=json.dumps({"order_id": f"chk-{tid[:8]}-{i}"}).encode(),
                                       headers={"Content-Type": "application/json",
                                                "traceparent": f"00-{tid}-{os.urandom(8).hex()}-01"})
          try:
              with urllib.request.urlopen(req, timeout=10) as r:
                  code = r.status
          except urllib.error.HTTPError as e:
              code = e.code
          except OSError as e:
              no(f"checkout did not answer ({e}). The end of /obs/logs/checkout.log:", *tail("checkout"))
          if code != 202:
              no(f"checkout answered {code} to an order from the check. The end of /obs/logs/checkout.log:",
                 *tail("checkout"))
          probes[tid] = None

      def batch_spans():
          """Every fulfil CONSUMER span since the check began: (span, its trace id)."""
          q = urllib.parse.urlencode({"q": '{resource.service.name="fulfil" && kind=consumer}',
                                      "start": since, "end": int(time.time()) + 1, "limit": 200, "spss": 50})
          try:
              found = get(f"{TEMPO}/api/search?{q}").get("traces", [])
          except OSError as e:
              no(f"Tempo did not answer a search ({e}).")
          out = []
          for t in found:
              tid = t["traceID"].rjust(32, "0")
              try:
                  full = get(f"{TEMPO}/api/traces/{tid}")
              except OSError:
                  continue
              for b in full.get("batches", []):
                  for ss in b.get("scopeSpans", []):
                      for s in ss.get("spans", []):
                          if s.get("kind") in ("SPAN_KIND_CONSUMER", 5):
                              out.append((s, tid))
          return out

      deadline = time.time() + 45
      while True:
          time.sleep(4)
          spans = batch_spans()
          reach = {}
          for s, tid in spans:
              # A parent counts only for a batch span that links the rest of its batch.
              n = next((int(a["value"].get("intValue", 0)) for a in s.get("attributes", [])
                        if a["key"] == "messaging.batch.message_count"), 0)
              if n >= 2 and len(s.get("links", [])) >= n - 1:
                  reach.setdefault(tid, ("parent", s))
              for l in s.get("links", []):
                  reach.setdefault(hexid(l["traceId"]), ("link", s, hexid(l["spanId"])))
          missing = [t for t in probes if t not in reach]
          if not missing or time.time() > deadline:
              break

      if not spans:
          no("Tempo has no fulfil CONSUMER span since the check began. Is fulfil running? The end of",
             "/obs/logs/fulfil.log:", *tail("fulfil"))
      if missing and len(spans) > N:
          no(f"fulfil made {len(spans)} CONSUMER spans for about {N} orders, without span links. One span",
             "per message gives every trace a fulfil span, and the batch is no longer one unit of work",
             "with one duration. Keep one span per batch and connect it to every order in it.")
      if missing:
          linked = sum(len(s.get("links", [])) for s, _ in spans)
          sizes = [next((a["value"].get("intValue") for a in s.get("attributes", [])
                         if a["key"] == "messaging.batch.message_count"), "?") for s, _ in spans]
          no(f"{len(missing)} of the {N} orders the check placed reach no fulfil batch span (trace",
             f"{missing[0]} for one). fulfil made {len(spans)} batch spans of {', '.join(map(str, sizes[:6]))}",
             f"{'...' if len(sizes) > 6 else ''} orders, with {linked} span links between them. A span has",
             "one parent, so an order that is not the parent needs a link from the batch span to its trace.")

      # A link must point at the order's producer span, not just carry its trace id.
      for tid in list(probes)[:8]:
          kind = reach[tid]
          if kind[0] != "link":
              continue
          try:
              full = get(f"{TEMPO}/api/traces/{tid}")
          except OSError as e:
              no(f"Tempo has no trace {tid}, which a fulfil span links to ({e}).")
          ids = {hexid(s["spanId"]): s for b in full.get("batches", []) for ss in b.get("scopeSpans", [])
                 for s in ss.get("spans", [])}
          if kind[2] not in ids:
              no(f"a fulfil batch span links to trace {tid}, span {kind[2]}, and that trace has no such",
                 "span. The link has to carry the span context the producer put in the message.")
          if ids[kind[2]]["name"] != "orders publish":
              no(f"a fulfil batch span links to span '{ids[kind[2]]['name']}' in trace {tid}. Link to the",
                 "context that came in the message: checkout's 'orders publish' span.")
      print(f"PASS — all {N} orders the check placed are reachable from the fulfil batch span that")
      print(f"processed them, across {len(spans)} batch spans.")
      PY
---
