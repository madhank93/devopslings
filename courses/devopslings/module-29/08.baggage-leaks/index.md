---
kind: lesson
title: "The payment provider knows which tenant every order is for"
description: |
  checkout puts the tenant id in baggage so ledger can tag its spans with
  it. The same baggage header goes out on checkout's call to the payment
  provider, a company outside yours. Keep the tenant on ledger's spans and off
  every request that leaves.
name: baggage-leaks
slug: baggage-leaks
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
      """checkout — places orders. POST /checkout on :8080.

      The caller names the tenant in X-Tenant-ID. checkout puts it in baggage,
      records the order with ledger and charges it with the payment provider.
      A few customers are simulated in-process so there is always traffic.
      """
      import json
      import random
      import threading
      import time
      import urllib.request
      from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

      from opentelemetry import baggage, context, propagate, trace
      from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
      from opentelemetry.sdk.resources import Resource
      from opentelemetry.sdk.trace import TracerProvider
      from opentelemetry.sdk.trace.export import BatchSpanProcessor

      provider = TracerProvider(resource=Resource.create({"service.name": "checkout"}))
      provider.add_span_processor(BatchSpanProcessor(
          OTLPSpanExporter(endpoint="http://tempo:4318/v1/traces"), schedule_delay_millis=500))
      trace.set_tracer_provider(provider)
      tracer = trace.get_tracer("checkout")

      LEDGER = "http://ledger:8080/entries"
      # The payment provider's API. It is another company's service; the lab
      # runs a stand-in for it on the billing host.
      PROVIDER = "http://billing:8080/v1/charges"


      def call(url, payload):
          headers = {"Content-Type": "application/json"}
          propagate.inject(headers)
          req = urllib.request.Request(url, data=json.dumps(payload).encode(), headers=headers)
          urllib.request.urlopen(req, timeout=3).read()


      def place(order, tenant, incoming):
          ctx = baggage.set_baggage("tenant.id", tenant, context=propagate.extract(incoming))
          token = context.attach(ctx)
          try:
              with tracer.start_as_current_span("POST /checkout", kind=trace.SpanKind.SERVER) as span:
                  span.set_attribute("tenant.id", tenant)
                  span.set_attribute("order.id", order["order_id"])
                  with tracer.start_as_current_span("POST /entries", kind=trace.SpanKind.CLIENT):
                      call(LEDGER, order)
                  with tracer.start_as_current_span("POST /v1/charges", kind=trace.SpanKind.CLIENT) as s:
                      s.set_attribute("server.address", "billing")
                      call(PROVIDER, {"reference": order["order_id"], "amount": order["amount"]})
          finally:
              context.detach(token)


      class Handler(BaseHTTPRequestHandler):
          def log_message(self, *a):
              pass

          def do_POST(self):
              order = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0) or 0)) or b"{}")
              order.setdefault("amount", 1000)
              try:
                  place(order, self.headers.get("X-Tenant-ID", "unknown"), self.headers)
                  code = 201
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
              body = json.dumps({"order_id": f"ord-{n}", "amount": random.randint(500, 9000)}).encode()
              req = urllib.request.Request("http://localhost:8080/checkout", data=body, headers={
                  "Content-Type": "application/json", "X-Tenant-ID": random.choice(["acme", "globex", "initech"])})
              try:
                  urllib.request.urlopen(req, timeout=5).read()
              except OSError:
                  pass
              time.sleep(random.uniform(0.5, 1.0))


      threading.Thread(target=customers, daemon=True).start()
      ThreadingHTTPServer.daemon_threads = True
      ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
      PY
      cat > /obs/apps/ledger.py <<'PY'
      """ledger — records orders. POST /entries on :8080.

      Every span ledger makes carries the tenant the order belongs to, taken
      from the baggage of the request.
      """
      import time
      from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

      from opentelemetry import baggage, context, propagate, trace
      from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
      from opentelemetry.sdk.resources import Resource
      from opentelemetry.sdk.trace import TracerProvider
      from opentelemetry.sdk.trace.export import BatchSpanProcessor

      provider = TracerProvider(resource=Resource.create({"service.name": "ledger"}))
      provider.add_span_processor(BatchSpanProcessor(
          OTLPSpanExporter(endpoint="http://tempo:4318/v1/traces"), schedule_delay_millis=500))
      trace.set_tracer_provider(provider)
      tracer = trace.get_tracer("ledger")


      class Handler(BaseHTTPRequestHandler):
          def log_message(self, *a):
              pass

          def do_POST(self):
              self.rfile.read(int(self.headers.get("Content-Length", 0) or 0))
              token = context.attach(propagate.extract(self.headers))
              try:
                  with tracer.start_as_current_span("POST /entries", kind=trace.SpanKind.SERVER) as s:
                      s.set_attribute("tenant.id", baggage.get_baggage("tenant.id") or "")
                      with tracer.start_as_current_span("INSERT entries") as db:
                          db.set_attribute("tenant.id", baggage.get_baggage("tenant.id") or "")
                          time.sleep(0.005)
              finally:
                  context.detach(token)
              self.send_response(201)
              self.send_header("Content-Length", "0")
              self.end_headers()


      ThreadingHTTPServer.daemon_threads = True
      ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
      PY
      cat > /obs/apps/billing.py <<'PY'
      """Stand-in for the payment provider, an outside company's API.

      POST /v1/charges takes a charge. GET /v1/_seen lists every request it
      received, headers included: what the provider's logs would hold.
      Not yours to change.
      """
      import json
      from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

      seen = []


      class Handler(BaseHTTPRequestHandler):
          def log_message(self, *a):
              pass

          def reply(self, code, body=b""):
              self.send_response(code)
              self.send_header("Content-Length", str(len(body)))
              self.end_headers()
              self.wfile.write(body)

          def do_POST(self):
              body = self.rfile.read(int(self.headers.get("Content-Length", 0) or 0))
              seen.append({"path": self.path, "headers": list(self.headers.items()),
                           "body": body.decode(errors="replace")})
              del seen[:-500]
              self.reply(201, b'{"status":"captured"}')

          def do_GET(self):
              if self.path == "/v1/_seen":
                  return self.reply(200, json.dumps(seen).encode())
              self.reply(404)


      ThreadingHTTPServer.daemon_threads = True
      ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
      PY
      for a in billing ledger checkout; do app_restart "$a"; app_up "$a"; done
      echo "scenario ready: checkout takes an order every second or so for tenants acme, globex and"
      echo "initech, records it with ledger and charges it with the payment provider (billing:8080,"
      echo "a stand-in for an outside company). The headers the provider received:"
      echo "  curl -s http://billing:8080/v1/_seen | jq '.[-1].headers'"
      echo "Source: /obs/apps/checkout.py and /obs/apps/ledger.py."

  verify_done:
    timeout_seconds: 120
    run: |
      python3 - <<'PY'
      import base64, hashlib, json, os, sys, time, urllib.error, urllib.request

      TEMPO = "http://tempo:3200"
      PROVIDER_SHA = "6540a7e70ffeee0ed46553c9b05366cc9a4d53c5123740b9c720ad21dc3cdc04"

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

      if hashlib.sha256(open("/obs/apps/billing.py", "rb").read()).hexdigest() != PROVIDER_SHA:
          no("/obs/apps/billing.py has changed. It stands in for the payment provider, another",
             "company's API: you cannot change what it receives or logs. Reset the lesson, or put",
             "it back, and fix the side that sends.")

      def started(app):
          try:
              return int(open(f"/obs/run/{app}.started").read())
          except (OSError, ValueError):
              return 0

      # supervise restarts an edited app within half a second; until then
      # .started still holds the previous start.
      time.sleep(1)
      time.sleep(max(0, max(started(a) for a in ("checkout", "ledger", "billing")) + 3 - time.time()))

      tenant = "probe-" + os.urandom(4).hex()
      orders = {}
      for i in range(6):
          tid, oid = os.urandom(16).hex(), f"chk-{tenant}-{i}"
          req = urllib.request.Request("http://checkout:8080/checkout",
                                       data=json.dumps({"order_id": oid, "amount": 4200}).encode(),
                                       headers={"Content-Type": "application/json", "X-Tenant-ID": tenant,
                                                "traceparent": f"00-{tid}-{os.urandom(8).hex()}-01"})
          try:
              with urllib.request.urlopen(req, timeout=10) as r:
                  code = r.status
          except urllib.error.HTTPError as e:
              code = e.code
          except OSError as e:
              no(f"checkout did not answer POST /checkout ({e}). The end of /obs/logs/checkout.log:", *tail("checkout"))
          if code != 201:
              no(f"checkout answered {code} to an order from the check. The end of /obs/logs/checkout.log:",
                 *tail("checkout"))
          orders[oid] = tid

      try:
          seen = get("http://billing:8080/v1/_seen")
      except OSError as e:
          no(f"the payment provider stand-in did not answer ({e}).")
      charged = {}
      for r in seen:
          for oid in orders:
              if oid in r["body"]:
                  charged[oid] = r
      if len(charged) < len(orders):
          no(f"the check placed {len(orders)} orders and the payment provider was asked to charge",
             f"{len(charged)} of them. Every order still has to be charged.")
      for oid, r in charged.items():
          for k, v in r["headers"]:
              if k.lower() == "baggage" or tenant in v or "tenant" in k.lower() or "tenant" in v.lower():
                  no(f"the payment provider received this header with order {oid}:",
                     f"  {k}: {v}",
                     "Anything checkout sends there is in another company's logs. The tenant must not",
                     "leave with the request.")

      def spans_of(tid):
          try:
              t = get(f"{TEMPO}/api/traces/{tid}")
          except urllib.error.HTTPError as e:
              if e.code == 404:
                  return []
              no(f"Tempo answered {e.code} for trace {tid}.")
          except OSError as e:
              no(f"Tempo did not answer ({e}).")
          out = []
          for b in t.get("batches", []):
              svc = next((a["value"].get("stringValue") for a in b.get("resource", {}).get("attributes", [])
                          if a["key"] == "service.name"), "?")
              for ss in b.get("scopeSpans", []):
                  for s in ss.get("spans", []):
                      attrs = {a["key"]: a["value"].get("stringValue") for a in s.get("attributes", [])}
                      out.append((svc, s["name"], attrs))
          return out

      deadline = time.time() + 30
      while True:
          traces = {oid: spans_of(tid) for oid, tid in orders.items()}
          ready = all(any(svc == "ledger" for svc, _, _ in sp) and any(svc == "checkout" for svc, _, _ in sp)
                      for sp in traces.values())
          if ready or time.time() > deadline:
              break
          time.sleep(2)

      for oid, sp in traces.items():
          if not any(svc == "checkout" for svc, _, _ in sp):
              no(f"Tempo has no checkout span for the check's order {oid} (trace {orders[oid]}). checkout",
                 "has to continue the traceparent it receives. The end of /obs/logs/checkout.log:", *tail("checkout"))
          if not any(svc == "ledger" for svc, _, _ in sp):
              no(f"the trace of order {oid} ({orders[oid]}) has no ledger span: the trace context no",
                 "longer reaches ledger. The end of /obs/logs/ledger.log:", *tail("ledger"))
          for svc, name, attrs in sp:
              if svc != "ledger" and name != "POST /checkout":
                  continue
              if attrs.get("tenant.id") != tenant:
                  got = attrs.get("tenant.id")
                  no(f"{svc}'s span '{name}' for order {oid} has tenant.id {got!r}, not {tenant!r}.",
                     "The tenant has to keep reaching every service inside the company; ledger reads it",
                     "from the baggage of the request it receives.")
      print(f"PASS — {len(orders)} orders: every checkout and ledger span carries tenant {tenant}, and the")
      print("payment provider received the charges with no baggage and no tenant in any header.")
      PY
---
