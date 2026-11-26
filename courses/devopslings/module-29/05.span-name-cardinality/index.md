---
kind: lesson
title: "Every new order adds a spanmetrics series"
description: |
  The Collector's spanmetrics connector turns checkout's spans into request
  and latency metrics, one series per span name. checkout names each span
  after the order it fetched, so every order makes a new series and the
  count only climbs. Template the span name, and keep the order id where a
  trace search can still find it.
name: span-name-cardinality
slug: span-name-cardinality
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
        # Request counts and latency histograms per service, span name, span
        # kind and status, built from the spans going past.
        spanmetrics:
          metrics_flush_interval: 5s

      exporters:
        otlphttp/tempo:
          endpoint: http://tempo:4318
        # Scraped by Prometheus as job "spanmetrics".
        prometheus:
          endpoint: 0.0.0.0:8889

      service:
        pipelines:
          traces:
            receivers: [otlp]
            processors: [batch]
            exporters: [otlphttp/tempo, spanmetrics]
          metrics/spanmetrics:
            receivers: [spanmetrics]
            exporters: [prometheus]
      YML
      cat >> /obs/prometheus/prometheus.yml <<'YML'

        - job_name: spanmetrics
          static_configs:
            - targets: ["collector:8889"]
      YML
      obs_reload >/dev/null
      cat > /obs/apps/checkout.py <<'PY'
      """checkout — GET /orders/<order id> on :8080 returns one order.

      Spans go to the Collector, which forwards them to Tempo and builds
      request metrics from them.
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


      def load_order(order_id):
          time.sleep(random.uniform(0.005, 0.02))
          return {"order_id": order_id, "status": "shipped"}


      class Handler(BaseHTTPRequestHandler):
          def log_message(self, *a):
              pass

          def do_GET(self):
              m = re.fullmatch(r"/orders/(\d+)", self.path)
              if not m:
                  self.send_error(404)
                  return
              order_id = m.group(1)
              ctx = propagate.extract(self.headers)
              with tracer.start_as_current_span(f"GET /orders/{order_id}", context=ctx,
                                                kind=trace.SpanKind.SERVER) as span:
                  span.set_attribute("order.id", order_id)
                  data = json.dumps(load_order(order_id)).encode()
              self.send_response(200)
              self.send_header("Content-Type", "application/json")
              self.send_header("Content-Length", str(len(data)))
              self.end_headers()
              self.wfile.write(data)


      ThreadingHTTPServer.daemon_threads = True
      ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
      PY
      app_restart collector
      app_up checkout
      collector_settle >/dev/null || true
      sleep 2
      for _ in $(seq 30); do curl -s -o /dev/null "checkout:8080/orders/$((RANDOM * 10 + RANDOM % 10))" || true; done
      echo "scenario ready: checkout serves GET /orders/<id> on :8080. The Collector's spanmetrics"
      echo "connector publishes its request metrics on collector:8889 (Prometheus job \"spanmetrics\")."
      echo "How many series checkout has, and what they are called:"
      echo "  promq 'count(traces_span_metrics_calls_total{service_name=\"checkout\"})'"
      echo "  promq 'traces_span_metrics_calls_total{service_name=\"checkout\"}' | head"
      echo "Source: /obs/apps/checkout.py. Collector: /obs/otel/collector.yaml"

  verify_done:
    timeout_seconds: 180
    run: |
      . /usr/local/lib/obs.sh
      collector_settle || exit 1
      python3 - <<'PY'
      import json, os, random, re, sys, time, urllib.error, urllib.request

      TEMPO = "http://tempo:3200"
      N = 50
      BUDGET = 5

      def no(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print(l)
          sys.exit(1)

      def checkout_span(tid):
          """(name, attributes) of checkout's span in a trace the check started, or None."""
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
              for ss in b.get("scopeSpans") or []:
                  for sp in ss.get("spans", []):
                      return sp["name"], {a["key"]: a["value"] for a in sp.get("attributes", [])}
          return None

      def series():
          """checkout's spanmetrics call-count series on the Collector: label set -> value."""
          try:
              text = urllib.request.urlopen("http://collector:8889/metrics", timeout=5).read().decode()
          except OSError as e:
              no(f"the Collector's metrics endpoint collector:8889 does not answer ({e}). The spanmetrics",
                 "connector and the prometheus exporter came with the scenario; keep them.")
          out = {}
          for l in text.splitlines():
              m = re.match(r'traces_span_metrics_calls_total\{(.*)\} (\S+)', l)
              if m and 'service_name="checkout"' in m.group(1):
                  out[m.group(1)] = float(m.group(2))
          return out

      def started(app):
          try:
              return int(open(f"/obs/run/{app}.started").read())
          except (OSError, ValueError):
              return 0

      time.sleep(1.5)
      time.sleep(max(0, max(started("checkout"), started("collector")) + 3 - time.time()))
      before = series()

      ids = [str(random.randrange(10**8, 10**9)) for _ in range(N)]
      sent = {}
      for i in ids:
          # A trace ID of the check's own, so it reads only its requests' spans.
          tid = os.urandom(16).hex()
          req = urllib.request.Request(f"http://checkout:8080/orders/{i}",
                                       headers={"traceparent": f"00-{tid}-{os.urandom(8).hex()}-01"})
          try:
              code = urllib.request.urlopen(req, timeout=5).status
          except OSError as e:
              no(f"checkout did not answer GET /orders/{i} ({e}). The end of /obs/logs/checkout.log:",
                 *["  " + l.rstrip()[:200] for l in open("/obs/logs/checkout.log").readlines()[-3:]])
          if code != 200:
              no(f"checkout answered GET /orders/{i} with {code}, not 200. Keep its responses as they were.")
          sent[tid] = i

      got = {}
      for _ in range(30):
          time.sleep(1)
          for tid in sent:
              if tid not in got:
                  sp = checkout_span(tid)
                  if sp is not None:
                      got[tid] = sp
          if len(got) == len(sent):
              break
      if len(got) < len(sent):
          no(f"the check sent {N} requests to checkout, each with a traceparent of its own, and Tempo has",
             f"checkout's span in {len(got)} of those traces after 30s. Keep checkout extracting the",
             "incoming context, and check /obs/logs/checkout.log and collector.log.")

      names = set()
      for tid, i in sent.items():
          name, attrs = got[tid]
          if i in name:
              no(f"checkout's span for order {i} is named {name!r}. The order id is in the span name, so",
                 "every order is a new name, and the connector makes a series per name. Name the span",
                 "after the route, GET /orders/{id}.")
          oid = attrs.get("order.id", {}).get("stringValue", attrs.get("order.id", {}).get("intValue"))
          if oid is None:
              no(f"the span for order {i} has no attribute order.id. The id was never what made the series:",
                 "spanmetrics does not use it. Put it back; it is how someone finds one order's trace.")
          if str(oid) != i:
              no(f"the span for order {i} has order.id {oid!r}. Set it from the request's path.")
          names.add(name)
      if len(names) != 1:
          no(f"checkout's spans have {len(names)} names over the check's {N} requests to one route:",
             f"{sorted(names)}.")
      name = names.pop()
      if not name.startswith("GET /orders/") or re.search(r"\d", name):
          no(f"checkout's spans are all named {name!r}. One name per route is right; say which route it",
             "is, as the HTTP conventions do: GET /orders/{id}.")

      want = sum(before.values()) + N
      after = before
      for _ in range(30):
          time.sleep(1)
          after = series()
          if sum(after.values()) >= want:
              break
      if sum(after.values()) < want:
          no(f"the spanmetrics connector counted {int(sum(after.values()) - sum(before.values()))} of the",
             f"check's {N} requests after 30s. Is it still an exporter of the traces pipeline and a",
             "receiver of the metrics one?")
      # Only the series of the check's own span name: spans checkout made before the check may land late.
      new = [k for k in after if k not in before and f'span_name="{name}"' in k]
      if len(new) > BUDGET:
          labs = [dict(re.findall(r'(\w+)="([^"]*)"', k)) for k in new]
          vals = lambda k: sorted({l[k] for l in labs if k in l})
          key = max({k for l in labs for k in l}, key=lambda k: len(vals(k)))
          no(f"the {N} requests made {len(new)} new spanmetrics series for checkout; the budget is {BUDGET}.",
             f"Among them the label {key} takes {len(vals(key))} values, such as {vals(key)[:3]}. A label",
             "that takes one value per order (a dimension added to the connector, say) grows the series",
             "as fast as an id in the span name did.")
      print(f"PASS — {N} fresh orders made {len(new)} new spanmetrics series (budget {BUDGET}); the spans are")
      print(f"named {name!r} and still carry each order's id as order.id.")
      PY
---
