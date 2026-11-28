---
kind: lesson
title: "Every service is traced, and the service graph is empty"
description: |
  checkout calls fulfil, fulfil calls ledger, every request is one trace
  with all three services in it, and the Collector's servicegraph connector
  has not produced a single edge. The connector is configured correctly.
  Find what it needs from the spans and give it that.
name: span-kind-and-the-empty-map
slug: span-kind-and-the-empty-map
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
      cat > /obs/otel/collector.yaml <<'YML'
      # The traces pipeline. Apps send OTLP over HTTP to collector:4318. Saving
      # this file restarts the Collector; its output is in /obs/logs/collector.log.
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

      connectors:
        # Builds request and latency metrics for each caller -> callee pair it
        # finds in the spans going past.
        servicegraph:
          metrics_flush_interval: 5s
          store:
            ttl: 5s

      exporters:
        otlphttp/tempo:
          endpoint: http://tempo:4318
        # Scraped by Prometheus as job "servicegraph".
        prometheus:
          endpoint: 0.0.0.0:8889

      service:
        pipelines:
          traces:
            receivers: [otlp]
            processors: [batch]
            exporters: [otlphttp/tempo, servicegraph]
          metrics/servicegraph:
            receivers: [servicegraph]
            exporters: [prometheus]
      YML
      cat >> /obs/prometheus/prometheus.yml <<'YML'

        - job_name: servicegraph
          static_configs:
            - targets: ["collector:8889"]
      YML
      obs_reload >/dev/null
      cat > /obs/apps/checkout.py <<'PY'
      """checkout — POST /checkout on :8080. Asks fulfil to reserve the order's stock."""
      import random
      import time
      import urllib.request
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


      def reserve_stock():
          with tracer.start_as_current_span("POST /reserve") as span:
              span.set_attribute("server.address", "fulfil")
              headers = {"Content-Type": "application/json"}
              propagate.inject(headers)
              req = urllib.request.Request("http://fulfil:8080/reserve", data=b"{}", headers=headers)
              urllib.request.urlopen(req, timeout=5).read()


      class Handler(BaseHTTPRequestHandler):
          def log_message(self, *a):
              pass

          def do_POST(self):
              self.rfile.read(int(self.headers.get("Content-Length", 0) or 0))
              ctx = propagate.extract(self.headers)
              with tracer.start_as_current_span("POST /checkout", context=ctx):
                  time.sleep(random.uniform(0.005, 0.02))
                  reserve_stock()
              self.send_response(200)
              self.send_header("Content-Length", "0")
              self.end_headers()


      ThreadingHTTPServer.daemon_threads = True
      ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
      PY
      cat > /obs/apps/fulfil.py <<'PY'
      """fulfil — POST /reserve on :8080. Reserves stock and books it with ledger."""
      import random
      import time
      import urllib.request
      from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

      from opentelemetry import propagate, trace
      from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
      from opentelemetry.sdk.resources import Resource
      from opentelemetry.sdk.trace import TracerProvider
      from opentelemetry.sdk.trace.export import BatchSpanProcessor

      provider = TracerProvider(resource=Resource.create({"service.name": "fulfil"}))
      provider.add_span_processor(BatchSpanProcessor(
          OTLPSpanExporter(endpoint="http://collector:4318/v1/traces"), schedule_delay_millis=500))
      trace.set_tracer_provider(provider)
      tracer = trace.get_tracer("fulfil")


      def book():
          with tracer.start_as_current_span("POST /entries") as span:
              span.set_attribute("server.address", "ledger")
              headers = {"Content-Type": "application/json"}
              propagate.inject(headers)
              req = urllib.request.Request("http://ledger:8080/entries", data=b"{}", headers=headers)
              urllib.request.urlopen(req, timeout=5).read()


      class Handler(BaseHTTPRequestHandler):
          def log_message(self, *a):
              pass

          def do_POST(self):
              self.rfile.read(int(self.headers.get("Content-Length", 0) or 0))
              ctx = propagate.extract(self.headers)
              with tracer.start_as_current_span("POST /reserve", context=ctx):
                  time.sleep(random.uniform(0.005, 0.02))
                  book()
              self.send_response(200)
              self.send_header("Content-Length", "0")
              self.end_headers()


      ThreadingHTTPServer.daemon_threads = True
      ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
      PY
      cat > /obs/apps/ledger.py <<'PY'
      """ledger — POST /entries on :8080. Records the booking."""
      import random
      import time
      import urllib.request
      from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

      from opentelemetry import propagate, trace
      from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
      from opentelemetry.sdk.resources import Resource
      from opentelemetry.sdk.trace import TracerProvider
      from opentelemetry.sdk.trace.export import BatchSpanProcessor

      provider = TracerProvider(resource=Resource.create({"service.name": "ledger"}))
      provider.add_span_processor(BatchSpanProcessor(
          OTLPSpanExporter(endpoint="http://collector:4318/v1/traces"), schedule_delay_millis=500))
      trace.set_tracer_provider(provider)
      tracer = trace.get_tracer("ledger")



      class Handler(BaseHTTPRequestHandler):
          def log_message(self, *a):
              pass

          def do_POST(self):
              self.rfile.read(int(self.headers.get("Content-Length", 0) or 0))
              ctx = propagate.extract(self.headers)
              with tracer.start_as_current_span("POST /entries", context=ctx):
                  time.sleep(random.uniform(0.005, 0.02))
              self.send_response(200)
              self.send_header("Content-Length", "0")
              self.end_headers()


      ThreadingHTTPServer.daemon_threads = True
      ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
      PY
      app_restart collector
      for a in ledger fulfil checkout; do app_up "$a"; done
      collector_settle >/dev/null || true
      for _ in $(seq 10); do curl -s -o /dev/null -XPOST checkout:8080/checkout || true; done
      echo "scenario ready: POST http://checkout:8080/checkout calls fulfil, which calls ledger."
      echo "All three send spans to the Collector, whose servicegraph connector publishes edges on"
      echo "collector:8889 (Prometheus job \"servicegraph\"). There are none:"
      echo "  promq 'traces_service_graph_request_total'"
      echo "Sources: /obs/apps/{checkout,fulfil,ledger}.py; the Collector: /obs/otel/collector.yaml"

  verify_done:
    timeout_seconds: 150
    run: |
      . /usr/local/lib/obs.sh
      collector_settle || exit 1
      python3 - <<'PY'
      import json, re, sys, time, urllib.parse, urllib.request

      TEMPO = "http://tempo:3200"
      EDGES = [("checkout", "fulfil"), ("fulfil", "ledger")]
      N = 20

      def no(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print(l)
          sys.exit(1)

      def get(url):
          with urllib.request.urlopen(url, timeout=10) as r:
              return json.load(r)

      def edges():
          try:
              text = urllib.request.urlopen("http://collector:8889/metrics", timeout=5).read().decode()
          except OSError as e:
              no(f"the Collector's metrics endpoint collector:8889 does not answer ({e}). The servicegraph",
                 "connector and the prometheus exporter came with the scenario; keep them.")
          out = {}
          for l in text.splitlines():
              m = re.match(r'traces_service_graph_request_total\{(.*)\} (\S+)', l)
              if m:
                  lab = dict(re.findall(r'(\w+)="([^"]*)"', m.group(1)))
                  k = (lab.get("client"), lab.get("server"))
                  out[k] = out.get(k, 0) + float(m.group(2))
          return out

      def started(app):
          try:
              return int(open(f"/obs/run/{app}.started").read())
          except (OSError, ValueError):
              return 0

      time.sleep(1.5)
      time.sleep(max(0, max(started(a) for a in ("checkout", "fulfil", "ledger")) + 2 - time.time()))
      since = int(time.time()) - 1
      before = edges()
      for _ in range(N):
          req = urllib.request.Request("http://checkout:8080/checkout", data=b"{}", method="POST")
          try:
              urllib.request.urlopen(req, timeout=10).read()
          except OSError as e:
              no(f"POST checkout:8080/checkout failed ({e}). The end of /obs/logs/checkout.log:",
                 *["  " + l.rstrip()[:200] for l in open("/obs/logs/checkout.log").readlines()[-3:]])

      got = {}
      for _ in range(40):
          time.sleep(1)
          now = edges()
          got = {e: now.get(e, 0) - before.get(e, 0) for e in EDGES}
          if all(v >= N for v in got.values()):
              break
      if all(v == N for v in got.values()):
          print(f"PASS — the service graph has checkout -> fulfil and fulfil -> ledger, each counting the")
          print(f"check's {N} requests exactly.")
          sys.exit(0)
      if any(v > N for v in got.values()):
          no(f"the edges counted {got} for the check's {N} requests. Something else is calling",
             "checkout while the check runs; stop it and check again.")

      # Explain the missing edge from the spans of one of the check's requests.
      p = urllib.parse.urlencode({"q": '{resource.service.name="checkout" && name="POST /checkout"}',
                                  "start": since, "end": int(time.time()) + 1, "limit": 5})
      found = get(f"{TEMPO}/api/search?{p}").get("traces", [])
      if not found:
          no(f"no edges, and Tempo has no 'POST /checkout' span from the check's {N} requests.")
      t = get(f"{TEMPO}/api/traces/{found[0]['traceID']}")
      ss = []
      for b in t.get("batches") or []:
          svc = next((a["value"].get("stringValue") for a in b["resource"]["attributes"] if a["key"] == "service.name"), "?")
          for sc in b.get("scopeSpans") or []:
              ss += [dict(s, service=svc) for s in sc.get("spans", [])]
      byid = {s["spanId"]: s for s in ss}
      services = {s["service"] for s in ss}
      if services != {"checkout", "fulfil", "ledger"}:
          no(f"trace {found[0]['traceID']} holds spans from {sorted(services)}, not all three services.",
             "The context has to travel on every call, as it did when the scenario started.")
      kind = lambda s: s.get("kind", "SPAN_KIND_INTERNAL").replace("SPAN_KIND_", "")
      for s in ss:
          parent = byid.get(s.get("parentSpanId"))
          if parent and parent["service"] != s["service"]:
              if kind(parent) != "CLIENT":
                  no(f"{parent['service']}'s '{parent['name']}' span, which calls {s['service']}, is",
                     f"{kind(parent)}. The connector starts an edge from a CLIENT span; an outgoing call",
                     "has to be one.")
              if kind(s) != "SERVER":
                  no(f"{s['service']}'s '{s['name']}' span, which handles {parent['service']}'s call, is",
                     f"{kind(s)}. The connector completes an edge with the SERVER span whose parent is the",
                     "CLIENT span; the span that receives a request has to be one.")
      no(f"the spans carry CLIENT and SERVER kinds and the edges counted {got} for the check's {N}",
         "requests after 40s. Is the servicegraph connector still an exporter of the traces pipeline",
         "and a receiver of the metrics one?")
      PY
---
