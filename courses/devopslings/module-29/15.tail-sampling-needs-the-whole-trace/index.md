---
kind: lesson
title: "Every error trace in Tempo has lost its root"
description: |
  Two gateway Collectors tail-sample: keep every trace with an error and one
  in ten of the rest. checkout's spans go to one gateway and ledger's to the
  other, so each decides on half a trace. Every error trace in Tempo is a
  ledger span with nothing above it. Make every stored trace whole.
name: tail-sampling-needs-the-whole-trace
slug: tail-sampling-needs-the-whole-trace
createdAt: "2026-11-22"

sandbox:
  stack: obs-stack
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 150
    run: |
      obs-reset >/dev/null
      . /usr/local/lib/obs.sh
      cat > /obs/apps/checkout.py <<'PY'
      """checkout — takes orders and records each one with ledger.

      Customers are simulated in-process. Spans go to the gateway in checkout's
      zone, collector. A ledger failure is retried later by a batch job, so
      checkout's own span stays OK. orders_total on :9101.
      """
      import json, random, time, urllib.error, urllib.request

      from opentelemetry import propagate, trace
      from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
      from opentelemetry.sdk.resources import Resource
      from opentelemetry.sdk.trace import TracerProvider
      from opentelemetry.sdk.trace.export import BatchSpanProcessor
      from prometheus_client import Counter, start_http_server

      provider = TracerProvider(resource=Resource.create({"service.name": "checkout"}))
      provider.add_span_processor(BatchSpanProcessor(
          OTLPSpanExporter(endpoint="http://collector:4318/v1/traces"), schedule_delay_millis=500))
      trace.set_tracer_provider(provider)
      tracer = trace.get_tracer("checkout")
      ORDERS = Counter("orders", "Orders taken.")


      def take_order(n):
          with tracer.start_as_current_span("POST /checkout", kind=trace.SpanKind.SERVER) as span:
              span.set_attribute("order.id", f"ord-{n}")
              time.sleep(random.uniform(0.01, 0.03))
              with tracer.start_as_current_span("POST /entries", kind=trace.SpanKind.CLIENT):
                  headers = {"Content-Type": "application/json"}
                  propagate.inject(headers)
                  req = urllib.request.Request("http://ledger:8080/entries",
                                               data=json.dumps({"order_id": f"ord-{n}"}).encode(), headers=headers)
                  try:
                      urllib.request.urlopen(req, timeout=2).read()
                  except urllib.error.HTTPError:
                      span.add_event("ledger entry deferred to the retry job")
          ORDERS.inc()


      start_http_server(9101)
      n = int(time.time()) % 100000 * 100
      while True:
          n += 1
          try:
              take_order(n)
          except Exception as e:
              print(f"order {n} failed: {e}", flush=True)
              time.sleep(1)
          time.sleep(random.uniform(0.2, 0.4))
      PY
      cat > /obs/apps/ledger.py <<'PY'
      """ledger — records orders. POST /entries on :8080. One write in twelve
      hits a lock timeout and fails with a 500. Spans go to the gateway in
      ledger's zone, collector-2."""
      import random, time
      from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

      from opentelemetry import propagate, trace
      from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
      from opentelemetry.sdk.resources import Resource
      from opentelemetry.sdk.trace import TracerProvider
      from opentelemetry.sdk.trace.export import BatchSpanProcessor

      provider = TracerProvider(resource=Resource.create({"service.name": "ledger"}))
      provider.add_span_processor(BatchSpanProcessor(
          OTLPSpanExporter(endpoint="http://collector-2:4318/v1/traces"), schedule_delay_millis=500))
      trace.set_tracer_provider(provider)
      tracer = trace.get_tracer("ledger")


      class Handler(BaseHTTPRequestHandler):
          def log_message(self, *a):
              pass

          def do_POST(self):
              self.rfile.read(int(self.headers.get("Content-Length", 0)))
              code = 201
              with tracer.start_as_current_span("POST /entries", context=propagate.extract(self.headers),
                                                kind=trace.SpanKind.SERVER) as span:
                  time.sleep(0.01)
                  if random.random() < 1 / 12:
                      span.set_status(trace.StatusCode.ERROR, "lock timeout on entries")
                      code = 500
              self.send_response(code)
              self.send_header("Content-Length", "0")
              self.end_headers()


      ThreadingHTTPServer.daemon_threads = True
      ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
      PY
      for f in collector collector-2; do
        cat > /obs/otel/$f.yaml <<YML
      # Gateway Collector '$f'. Saving this file restarts it; its output is in
      # /obs/logs/$f.log.
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
        # Keep every trace with an error, and one in ten of the rest.
        tail_sampling:
          decision_wait: 5s
          policies:
            - name: errors
              type: status_code
              status_code:
                status_codes: [ERROR]
            - name: one-in-ten
              type: probabilistic
              probabilistic:
                sampling_percentage: 10

      exporters:
        otlphttp/tempo:
          endpoint: http://tempo:4318

      service:
        pipelines:
          traces:
            receivers: [otlp]
            processors: [tail_sampling, batch]
            exporters: [otlphttp/tempo]
      YML
      done
      for a in collector-2 ledger checkout; do app_up "$a"; done
      app_restart collector
      collector_settle >/dev/null || true
      echo "scenario ready: checkout calls ledger for every order. checkout's spans go to the gateway"
      echo "'collector', ledger's to 'collector-2'; both tail-sample (/obs/otel/collector.yaml, collector-2.yaml)."
      echo "Error traces as Tempo has them:"
      echo "  curl -s -G http://tempo:3200/api/search --data-urlencode 'q={status=error}' | jq '.traces[].rootServiceName'"

  verify_done:
    timeout_seconds: 240
    run: |
      python3 - <<'PY'
      import json, re, sys, time, urllib.parse, urllib.request
      import yaml

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
          return ["  " + l[:250] for l in lines[-3:]] or ["  (nothing)"]

      def seconds(v):
          m = re.fullmatch(r"(\d+)(ms|s|m)", str(v).strip())
          return int(m.group(1)) * {"ms": 0.001, "s": 1, "m": 60}[m.group(2)] if m else 30

      for app, gw in (("checkout", "collector"), ("ledger", "collector-2")):
          if f'endpoint="http://{gw}:4318/v1/traces"' not in open(f"/obs/apps/{app}.py").read():
              no(f"{app}.py no longer sends its spans to {gw}. A service does not get to pick the gateway",
                 "that sees the rest of its trace; the routing belongs in the gateways.")

      time.sleep(1.5)
      cfgs, wait = {}, 0
      for c in ("collector", "collector-2"):
          for _ in range(25):
              if time.time() - started(c) >= 3:
                  break
              time.sleep(1)
          else:
              no(f"{c} will not stay up with /obs/otel/{c}.yaml. The end of /obs/logs/{c}.log:", *tail(c))
          try:
              cfgs[c] = yaml.safe_load(open(f"/obs/otel/{c}.yaml")) or {}
          except (OSError, yaml.YAMLError) as e:
              no(f"/obs/otel/{c}.yaml does not parse: {e}")
          for p in (cfgs[c].get("processors") or {}).values():
              if isinstance(p, dict) and "decision_wait" in p:
                  wait = max(wait, seconds(p["decision_wait"]))
      if wait > 120:
          no(f"decision_wait is {wait:g}s. The gateways hold every trace in memory that long, and the",
             "trace is no more complete at the end of it.")

      since = max(started(a) for a in ("collector", "collector-2", "checkout", "ledger")) + 3
      until = since + 45
      time.sleep(max(0, until + wait + 10 - time.time()))

      def search(q):
          p = urllib.parse.urlencode({"q": q, "start": since, "end": until, "limit": 1000})
          try:
              return get(f"{TEMPO}/api/search?{p}").get("traces", [])
          except OSError as e:
              no(f"Tempo did not answer a search ({e}).")

      errs = search('{resource.service.name="ledger" && status=error}')
      if len(errs) < 3:
          no(f"Tempo holds {len(errs)} traces with a failed ledger write from a 45s window; about one write",
             "in twelve fails, so there should be ten or more. Every error trace has to be kept. The end",
             "of /obs/logs/collector-2.log:", *tail("collector-2"))
      frag = [t for t in errs if t.get("rootServiceName") != "checkout"]
      if frag:
          extra = (f" decision_wait is {wait:g}s; waiting longer does not bring checkout's half to the"
                   " gateway that saw the error.") if wait > 5 else ""
          no(f"{len(frag)} of the {len(errs)} error traces in Tempo have no checkout span: ledger's gateway",
             "kept its half because it saw the error, and checkout's gateway, which never saw it, sampled",
             f"its half away.{extra} Every span of a trace has to reach the same gateway.")

      led = {t["traceID"] for t in search('{resource.service.name="ledger"}')}
      chk = search('{resource.service.name="checkout" && name="POST /checkout"}')
      partial = [t for t in chk if t["traceID"] not in led]
      if partial:
          no(f"{len(partial)} of the {len(chk)} checkout traces in Tempo have no ledger span (trace",
             f"{partial[0]['traceID']}).")
      orders = 45 / 0.33
      if len(chk) > orders * 0.35:
          no(f"Tempo stored {len(chk)} checkout traces from a 45s window of roughly {orders:.0f} orders. The",
             "budget is every error trace and one in ten of the rest: keep the sampler.")

      kind = lambda names: {str(n).split("/")[0] for n in names or []}
      for c, cfg in cfgs.items():
          pipes = [p or {} for p in ((cfg.get("service") or {}).get("pipelines") or {}).values()]
          routed = [p for p in pipes if "loadbalancing" in kind(p.get("exporters"))]
          if not routed:
              no(f"{c} sends nothing through a loadbalancing exporter. Traces are whole today, but whatever made",
                 "them whole is not routing by trace ID, and the next gateway added splits them again.")
          if any("tail_sampling" in kind(p.get("processors")) for p in routed):
              no(f"{c} tail-samples in the same pipeline that routes by trace ID, so it decides on the half of",
                 "the trace it was sent before routing. Route first; sample in a second pipeline.")
          if any("tail_sampling" in kind(p.get("processors")) and "otlp" in (p.get("receivers") or []) for p in pipes):
              no(f"{c}'s tail_sampling still reads straight from the services' otlp receiver, so it samples",
                 "whatever half of a trace a service sent it. Sample only what the loadbalancing exporter routed.")
          lb = [e for p in routed for e in p.get("exporters") or [] if e.split("/")[0] == "loadbalancing"]
          if (cfg["exporters"][lb[0]] or {}).get("routing_key", "traceID") != "traceID":
              no(f"{c}'s loadbalancing exporter routes by {cfg['exporters'][lb[0]].get('routing_key')}, not traceID.")
          res = (cfg["exporters"][lb[0]] or {}).get("resolver") or {}
          hosts = [str(h).split(":")[0] for h in (res.get("static") or {}).get("hostnames") or []]
          if "dns" not in res and not {"collector", "collector-2"} <= set(hosts):
              no(f"{c}'s loadbalancing exporter sends to {', '.join(hosts) or 'nothing'}. With one gateway in the list,",
                 "that gateway samples every trace on its own; list both, so the load is shared by trace ID.")
      print(f"PASS — {len(errs)} error traces and {len(chk)} sampled traces in Tempo, every one with checkout")
      print("and ledger in it: both gateways route spans by trace ID before tail sampling.")
      PY
---
