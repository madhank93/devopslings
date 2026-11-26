---
kind: lesson
title: "checkout has traces and no metrics"
description: |
  checkout sends a span for every request through the Collector, and Tempo
  keeps one trace in ten. There is no request rate, error rate or latency
  graph for it anywhere, and nobody wants to add a metrics library to it.
  Get rate, errors and duration per route out of the spans it already sends,
  counting every request.
name: red-from-spans
slug: red-from-spans
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
      """checkout — the shop's cart and checkout API on :8080.

        GET  /cart          the customer's cart
        POST /checkout      places an order; a declined card is a 500
        GET  /orders/<id>   one order

      Every request is a span, sent to the Collector. No metrics library.
      """
      import random
      import re
      import time
      from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

      from opentelemetry import trace
      from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
      from opentelemetry.sdk.resources import Resource
      from opentelemetry.sdk.trace import TracerProvider
      from opentelemetry.sdk.trace.export import BatchSpanProcessor

      provider = TracerProvider(resource=Resource.create({"service.name": "checkout"}))
      provider.add_span_processor(BatchSpanProcessor(
          OTLPSpanExporter(endpoint="http://collector:4318/v1/traces"),
          schedule_delay_millis=500, max_queue_size=20000))
      trace.set_tracer_provider(provider)
      tracer = trace.get_tracer("checkout")


      class Handler(BaseHTTPRequestHandler):
          protocol_version = "HTTP/1.1"

          def log_message(self, *a):
              pass

          def reply(self, code, body=b"ok"):
              self.send_response(code)
              self.send_header("Content-Length", str(len(body)))
              self.end_headers()
              self.wfile.write(body)

          def handle_one(self, method):
              body = self.rfile.read(int(self.headers.get("Content-Length", 0) or 0))
              path = self.path.split("?")[0]
              if method == "GET" and path == "/cart":
                  route = "/cart"
              elif method == "POST" and path == "/checkout":
                  route = "/checkout"
              elif method == "GET" and re.fullmatch(r"/orders/\d+", path):
                  route = "/orders/{id}"
              else:
                  return self.reply(404, b"no such route")
              with tracer.start_as_current_span(f"{method} {route}", kind=trace.SpanKind.SERVER) as span:
                  span.set_attribute("http.request.method", method)
                  span.set_attribute("http.route", route)
                  time.sleep(random.uniform(0.02, 0.05) if route == "/checkout" else random.uniform(0.003, 0.01))
                  if route == "/checkout" and b"decline" in body:
                      span.set_attribute("http.response.status_code", 500)
                      span.set_status(trace.StatusCode.ERROR, "card declined")
                      return self.reply(500, b"card declined")
                  span.set_attribute("http.response.status_code", 200)
                  self.reply(200)

          def do_GET(self):
              self.handle_one("GET")

          def do_POST(self):
              self.handle_one("POST")


      ThreadingHTTPServer.daemon_threads = True
      ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
      PY
      cat > /obs/otel/collector.yaml <<'YML'
      # The OpenTelemetry Collector. Saving this file restarts it; its output,
      # including a config it refuses, is in /obs/logs/collector.log.
      receivers:
        otlp:
          protocols:
            http:
              endpoint: 0.0.0.0:4318
            grpc:
              endpoint: 0.0.0.0:4317

      processors:
        batch:
          timeout: 1s
        # Tempo keeps one trace in ten: storing every one costs more than it answers.
        probabilistic_sampler:
          sampling_percentage: 10

      exporters:
        otlphttp/loki:
          endpoint: http://loki:3100/otlp
        otlphttp/tempo:
          endpoint: http://tempo:4318

      service:
        telemetry:
          metrics:
            readers:
              - pull:
                  exporter:
                    prometheus:
                      host: 0.0.0.0
                      port: 8888
        pipelines:
          logs:
            receivers: [otlp]
            processors: [batch]
            exporters: [otlphttp/loki]
          traces:
            receivers: [otlp]
            processors: [probabilistic_sampler, batch]
            exporters: [otlphttp/tempo]
      YML
      app_up checkout
      collector_settle >/dev/null || true
      for i in $(seq 1 30); do curl -sf -o /dev/null http://checkout:8080/cart && break; sleep 1; done
      echo "scenario ready: checkout serves GET /cart, POST /checkout and GET /orders/<id> on"
      echo "checkout:8080, and sends a span per request to the Collector (/obs/otel/collector.yaml)."
      echo "Prometheus (/obs/prometheus/prometheus.yml) has nothing from it. Try some traffic:"
      echo "  for i in \$(seq 50); do curl -s -o /dev/null http://checkout:8080/cart; done"

  verify_done:
    timeout_seconds: 240
    run: |
      . /usr/local/lib/obs.sh
      obs_require_loaded || exit 1
      collector_settle || exit 1
      # A fresh Collector starts its span counters at zero, so what Prometheus
      # reads after the load below is the load and nothing else.
      app_restart collector
      collector_settle || exit 1
      sleep 8
      python3 - <<'PY'
      import json, re, sys, time, urllib.error, urllib.parse, urllib.request
      from concurrent.futures import ThreadPoolExecutor

      PROM, TEMPO = "http://prometheus:9090", "http://tempo:3200"
      LOAD = {"GET /cart": 400, "POST /checkout": 300, "GET /orders/{id}": 200}
      DECLINED = 60

      def no(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print(l)
          sys.exit(1)

      def get(url, **params):
          with urllib.request.urlopen(f"{url}?{urllib.parse.urlencode(params)}" if params else url, timeout=10) as r:
              return json.load(r)

      def q(expr):
          try:
              return get(f"{PROM}/api/v1/query", query=expr)["data"]["result"]
          except OSError as e:
              no(f"Prometheus did not answer ({e}).")

      def send(i):
          if i < 400:
              req = urllib.request.Request("http://checkout:8080/cart")
          elif i < 700:
              body = b'{"card":"decline"}' if i < 400 + DECLINED else b'{"card":"ok"}'
              req = urllib.request.Request("http://checkout:8080/checkout", data=body)
          else:
              req = urllib.request.Request(f"http://checkout:8080/orders/{100000 + i}")
          try:
              urllib.request.urlopen(req, timeout=10).read()
              return 200
          except urllib.error.HTTPError as e:
              return e.code
          except OSError:
              return 0

      t0 = int(time.time())
      with ThreadPoolExecutor(8) as ex:
          codes = list(ex.map(send, range(900)))
      if codes.count(0):
          no(f"{codes.count(0)} of the check's 900 requests to checkout:8080 got no answer. Is checkout",
             "running? The end of /obs/logs/checkout.log:",
             *["  " + l.rstrip()[:200] for l in open("/obs/logs/checkout.log").readlines()[-3:]])

      names = '{span_name=~"GET /cart|POST /checkout|GET /orders/\\\\{id\\\\}"}'
      def metric_names():
          return sorted({r["metric"]["__name__"] for r in q(f"group by (__name__) ({names})")})

      def counts(calls):
          out = {}
          for r in q(f"sum by (span_name, status_code) ({calls}{names})"):
              k = (r["metric"].get("span_name"), r["metric"].get("status_code", ""))
              out[k] = float(r["value"][1])
          return out

      def total(c, route):
          return sum(v for (s, _), v in c.items() if s == route)

      deadline = time.time() + 120
      calls = None
      while time.time() < deadline:
          found = metric_names()
          calls = next((n for n in found if re.search(r"calls(_total)?$", n)), None)
          if calls and all(total(counts(calls), r) >= n * 0.98 for r, n in LOAD.items()):
              time.sleep(6)
              break
          time.sleep(5)

      if not calls:
          cfg = open("/obs/otel/collector.yaml").read()
          if "spanmetrics" not in cfg:
              no("the Collector has no spanmetrics connector, and nothing else turns spans into",
                 "request counts. See /obs/otel/collector.yaml.")
          targets = get(f"{PROM}/api/v1/targets")["data"]["activeTargets"]
          coll = [t for t in targets if t["labels"].get("instance", "").startswith("collector:")
                  or t.get("scrapeUrl", "").startswith("http://collector:")]
          if not coll:
              no("Prometheus scrapes nothing on the Collector, so whatever the connector counts stays",
                 "there. Add a scrape job for the endpoint of the Collector's prometheus exporter.")
          down = [t for t in coll if t["health"] != "up"]
          if down:
              no(f"Prometheus cannot scrape {down[0]['scrapeUrl']}: {down[0].get('lastError') or down[0]['health']}.")
          if all(":8888" in t["scrapeUrl"] for t in coll):
              no("Prometheus scrapes the Collector on :8888, which is the Collector's own telemetry:",
                 "spans received and exported, queue sizes. The connector's metrics leave through an",
                 "exporter in a metrics pipeline, on a port of their own.")
          no(f"Prometheus scrapes {', '.join(t['scrapeUrl'] for t in coll)} and has no span metrics for",
             "checkout's routes 120s after the check's load. spanmetrics has to be an exporter of a",
             "traces pipeline and a receiver of a metrics pipeline whose exporter Prometheus scrapes;",
             "its metrics_flush_interval decides how soon they show up (the default is 60s).")

      c = counts(calls)
      for route, n in LOAD.items():
          got = total(c, route)
          if abs(got - n) > n * 0.02:
              if 0 < got < n * 0.5:
                  no(f"{calls} counted {got:g} '{route}' requests where the check sent {n}: about one",
                     "in ten. The connector sees spans after probabilistic_sampler has dropped nine in",
                     "ten. RED has to count every request; sample only what goes on to Tempo.")
              no(f"{calls} counted {got:g} '{route}' requests where the check sent {n}.",
                 "The counts have to come from every span checkout sent, once each.")
      errs = sum(v for (s, st), v in c.items() if s == "POST /checkout" and "ERROR" in st.upper())
      if abs(errs - DECLINED) > DECLINED * 0.02:
          no(f"{calls} has {errs:g} 'POST /checkout' calls with an error status; the check sent {DECLINED}",
             "declined cards, each a 500 with its span status set to ERROR. Keep status_code as a dimension.")

      found = metric_names()
      dur = next((n for n in found if re.search(r"duration.*_count$", n)), None)
      if not dur:
          no(f"Prometheus has {calls} for checkout's routes and no duration histogram next to it",
             f"(it has: {', '.join(found)}). Rate and errors are two of the three; keep the histogram.")
      dc = {r["metric"].get("span_name"): float(r["value"][1])
            for r in q(f"sum by (span_name) ({dur}{names})")}
      for route, n in LOAD.items():
          if abs(dc.get(route, 0) - n) > n * 0.02:
              no(f"{dur} counted {dc.get(route, 0):g} '{route}' requests where the check sent {n}.")

      time.sleep(3)
      p = urllib.parse.urlencode({"q": '{resource.service.name="checkout" && name="GET /cart"}',
                                  "start": t0 - 1, "end": int(time.time()), "limit": 1000})
      try:
          stored = len(get(f"{TEMPO}/api/search?{p}").get("traces", []))
      except OSError as e:
          no(f"Tempo did not answer a search ({e}).")
      if stored == 0:
          no("Tempo stored none of the check's 400 'GET /cart' traces. The traces still go to Tempo,",
             "one in ten of them.")
      if stored > 100:
          no(f"Tempo stored {stored} of the check's 400 'GET /cart' traces. The sampler is there to keep",
             "storage at one trace in ten; the metrics can count everything without Tempo storing it.")
      print(f"PASS — {calls} and {dur} count every request per route within 2% (400 / 300 / 200,")
      print(f"{DECLINED} errors), while Tempo kept {stored} of 400 cart traces.")
      PY
---
