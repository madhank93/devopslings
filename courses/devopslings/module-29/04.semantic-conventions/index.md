---
kind: lesson
title: "checkout's spans say url and httpStatus, and nobody can group latency by route"
description: |
  checkout's spans carry the request as `url` and the response as
  `httpStatus`, names someone made up. Grafana's trace views, the spanmetrics
  connector and every other tool look for the OpenTelemetry names and find
  nothing, and the raw URLs, one per order, would not group if they did.
  Give the spans the standard attributes, with a route that groups.
name: semantic-conventions
slug: semantic-conventions
createdAt: "2026-11-22"

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
      """checkout — the order API on :8080.

          GET  /orders/<order id>               one order (404 when there is no such order)
          GET  /customers/<customer id>/orders  a customer's orders
          POST /orders                          place an order

      Spans go to the Collector, which forwards them to Tempo.
      """
      import json
      import random
      import re
      import time
      from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

      from opentelemetry import propagate, trace
      from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
      from opentelemetry.sdk.resources import Resource
      from opentelemetry.sdk.trace import TracerProvider
      from opentelemetry.sdk.trace.export import BatchSpanProcessor

      provider = TracerProvider(resource=Resource.create({"service.name": "checkout"}))
      provider.add_span_processor(BatchSpanProcessor(
          OTLPSpanExporter(endpoint="http://collector:4318/v1/traces"), schedule_delay_millis=500))
      trace.set_tracer_provider(provider)
      tracer = trace.get_tracer("checkout")


      def get_order(order_id):
          time.sleep(random.uniform(0.005, 0.02))
          if int(order_id) % 2:
              return 404, {"error": "no such order"}
          return 200, {"order_id": order_id, "items": 3}


      def customer_orders(customer_id):
          time.sleep(random.uniform(0.02, 0.05))
          return 200, {"customer_id": customer_id, "orders": []}


      def place_order(_):
          time.sleep(random.uniform(0.03, 0.06))
          return 201, {"order_id": str(random.randrange(10**6))}


      ROUTES = [
          ("GET", r"/orders/(\d+)", get_order),
          ("GET", r"/customers/(\d+)/orders", customer_orders),
          ("POST", r"/orders", place_order),
      ]


      class Handler(BaseHTTPRequestHandler):
          def log_message(self, *a):
              pass

          def handle_request(self):
              self.rfile.read(int(self.headers.get("Content-Length", 0) or 0))
              ctx = propagate.extract(self.headers)
              with tracer.start_as_current_span("handle request", context=ctx, kind=trace.SpanKind.SERVER) as span:
                  span.set_attribute("method", self.command)
                  span.set_attribute("url", self.path)
                  status, body = 404, {"error": "not found"}
                  for method, pattern, fn in ROUTES:
                      m = re.fullmatch(pattern, self.path)
                      if m and method == self.command:
                          status, body = fn(*m.groups()) if m.groups() else fn(None)
                          break
                  span.set_attribute("httpStatus", str(status))
              data = json.dumps(body).encode()
              self.send_response(status)
              self.send_header("Content-Type", "application/json")
              self.send_header("Content-Length", str(len(data)))
              self.end_headers()
              self.wfile.write(data)

          do_GET = do_POST = handle_request


      ThreadingHTTPServer.daemon_threads = True
      ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
      PY
      app_up checkout
      echo "scenario ready: checkout serves GET /orders/<id>, GET /customers/<id>/orders and POST /orders"
      echo "on :8080 and sends its spans through the Collector to Tempo. What its spans carry:"
      echo "  curl -s checkout:8080/orders/1042; curl -s 'http://tempo:3200/api/search/tags?scope=span' | jq"
      echo "Source: /obs/apps/checkout.py. Collector: /obs/otel/collector.yaml"

  verify_done:
    timeout_seconds: 150
    run: |
      . /usr/local/lib/obs.sh
      collector_settle || exit 1
      python3 - <<'PY'
      import json, os, random, sys, time, urllib.error, urllib.request

      TEMPO = "http://tempo:3200"

      def no(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print(l)
          sys.exit(1)

      def server_span(tid):
          """checkout's span in the trace the check started, or None while Tempo does not have it."""
          try:
              with urllib.request.urlopen(f"{TEMPO}/api/traces/{tid}", timeout=10) as r:
                  t = json.load(r)
          except urllib.error.HTTPError as e:
              if e.code == 404:
                  return None
              no(f"Tempo answered {e.code} for trace {tid}.")
          except OSError as e:
              no(f"Tempo did not answer ({e}).")
          for b in t.get("batches") or []:
              svc = next((a["value"].get("stringValue") for a in b["resource"]["attributes"]
                          if a["key"] == "service.name"), "")
              if svc != "checkout":
                  continue
              for ss in b.get("scopeSpans") or []:
                  for sp in ss.get("spans", []):
                      return {a["key"]: a["value"] for a in sp.get("attributes", [])}
          return None

      def started(app):
          try:
              return int(open(f"/obs/run/{app}.started").read())
          except (OSError, ValueError):
              return 0

      time.sleep(1.5)
      time.sleep(max(0, max(started("checkout"), started("collector")) + 3 - time.time()))

      ids, reqs = set(), []
      for _ in range(10):
          i = str(random.randrange(10**6, 10**7))
          ids.add(i)
          reqs.append(("GET", f"/orders/{i}"))
      for _ in range(10):
          i = str(random.randrange(10**6, 10**7))
          ids.add(i)
          reqs.append(("GET", f"/customers/{i}/orders"))
      reqs += [("POST", "/orders")] * 10
      random.shuffle(reqs)
      sent = []
      for method, path in reqs:
          # A trace ID of the check's own, so it reads only its requests' spans.
          tid = os.urandom(16).hex()
          req = urllib.request.Request(f"http://checkout:8080{path}", data=b"{}" if method == "POST" else None,
                                       method=method, headers={"traceparent": f"00-{tid}-{os.urandom(8).hex()}-01"})
          try:
              code = urllib.request.urlopen(req, timeout=5).status
          except urllib.error.HTTPError as e:
              code = e.code
          except OSError as e:
              no(f"checkout did not answer {method} {path} ({e}). The end of /obs/logs/checkout.log:",
                 *["  " + l.rstrip()[:200] for l in open("/obs/logs/checkout.log").readlines()[-3:]])
          sent.append((method, path, code, tid))

      got = {}
      for _ in range(30):
          time.sleep(1)
          for r in sent:
              if r[3] not in got:
                  a = server_span(r[3])
                  if a is not None:
                      got[r[3]] = a
          if len(got) == len(sent):
              break
      if len(got) < len(sent):
          no(f"the check sent {len(sent)} requests to checkout, each with a traceparent of its own, and Tempo",
             f"has checkout's span in {len(got)} of those traces after 30s. Keep checkout extracting the",
             "incoming context, and check /obs/logs/checkout.log and collector.log.")

      def num(v):
          return v.get("intValue", v.get("doubleValue"))

      routes = set()
      for method, path, code, tid in sent:
          a = got[tid]
          st = a.get("http.response.status_code")
          if st is None:
              if "http.status_code" in a:
                  no("the spans carry http.status_code. That is the name before semantic conventions 1.21;",
                     "the stable HTTP conventions name it http.response.status_code, and current tools read that.")
              no(f"checkout's span for {method} {path} has no http.response.status_code. Renaming in a",
                 "dashboard leaves the spans, and every other tool reading them, with httpStatus.")
          if "stringValue" in st:
              no(f"http.response.status_code is the string {st['stringValue']!r}. The convention makes it an",
                 "integer, and a query like status_code >= 500 only compares integers. httpStatus was a",
                 "string; convert it (int() in the SDK, Int() in OTTL).")
          if int(num(st)) != code:
              no(f"checkout answered {method} {path} with {code}, and its span says",
                 f"http.response.status_code = {num(st)}.")
          route = a.get("http.route", {}).get("stringValue")
          if not route:
              no(f"checkout's span for {method} {path} has no http.route. It is the route template the request",
                 "matched, such as /orders/{id}: the one attribute that groups requests by endpoint.")
          if any(i in route for i in ids):
              no(f"http.route is {route!r} on the span for {method} {path}. That is the request's path, and",
                 "every order makes a new one. The route is the template the path matched, with the ids",
                 "left out: /orders/{id}.")
          routes.add(route)
      routes = sorted(routes)
      if len(routes) > 3:
          no(f"http.route has {len(routes)} values, {routes}, and checkout has three routes.")
      if len(routes) < 3:
          no(f"http.route has only {routes} over checkout's three routes; a route that groups requests",
             "of different endpoints together cannot tell them apart.")
      codes = {}
      for r in sent:
          codes[r[2]] = codes.get(r[2], 0) + 1
      print(f"PASS — checkout's spans carry http.response.status_code as an integer ({dict(sorted(codes.items()))})")
      print(f"and http.route, which groups the check's {len(sent)} requests into {len(routes)} routes: {', '.join(routes)}.")
      PY
---
