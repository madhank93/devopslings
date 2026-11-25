---
kind: lesson
title: "Something behind checkout is slow, and every graph blames shop"
description: |
  Orders take a third of a second, and the per-service latency graph puts
  shop at the top, then checkout. Both of those numbers include the time
  spent waiting on the services they call. Draw the service graph from the
  spans, and name the one call that is actually slow, with the metric that
  shows it.
name: service-map
slug: service-map
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
      cat > /obs/apps/mesh.py <<'PY'
      """mesh — the HTTP service shop, checkout, billing and ledger are built from.

      Each request is a SERVER span; each call to another service is a CLIENT
      span with the trace context injected. Spans go to the Collector.
      """
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


      def serve(name, work, calls=(), customers=False):
          """work: (low, high) seconds of the service's own time per request.
          calls: (service, path) pairs, called in order on every request."""
          provider = TracerProvider(resource=Resource.create({"service.name": name}))
          provider.add_span_processor(BatchSpanProcessor(
              OTLPSpanExporter(endpoint="http://collector:4318/v1/traces"), schedule_delay_millis=500))
          tracer = provider.get_tracer(name)

          def handle(span_name, ctx=None):
              with tracer.start_as_current_span(span_name, context=ctx, kind=trace.SpanKind.SERVER):
                  time.sleep(random.uniform(*work))
                  for svc, path in calls:
                      with tracer.start_as_current_span(f"POST {path}", kind=trace.SpanKind.CLIENT) as s:
                          s.set_attribute("server.address", svc)
                          headers = {"Content-Type": "application/json"}
                          propagate.inject(headers)
                          req = urllib.request.Request(f"http://{svc}:8080{path}", data=b"{}", headers=headers)
                          urllib.request.urlopen(req, timeout=5).read()

          class Handler(BaseHTTPRequestHandler):
              def log_message(self, *a):
                  pass

              def do_POST(self):
                  self.rfile.read(int(self.headers.get("Content-Length", 0) or 0))
                  handle(f"POST {self.path}", propagate.extract(self.headers))
                  self.send_response(200)
                  self.send_header("Content-Length", "0")
                  self.end_headers()

          if customers:
              def shoppers():
                  while True:
                      try:
                          handle("POST /order")
                      except Exception as e:
                          print(f"order failed: {e}", flush=True)
                          time.sleep(1)
                      time.sleep(random.uniform(0.2, 0.4))
              for _ in range(3):
                  threading.Thread(target=shoppers, daemon=True).start()
          ThreadingHTTPServer.daemon_threads = True
          ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
      PY
      cat > /obs/apps/shop.py <<'PY'
      """shop — the storefront. Customers place orders; shop hands each to checkout."""
      from mesh import serve
      serve("shop", work=(0.003, 0.008), calls=[("checkout", "/checkout")], customers=True)
      PY
      cat > /obs/apps/checkout.py <<'PY'
      """checkout — records the order with ledger, then has billing charge it."""
      from mesh import serve
      serve("checkout", work=(0.005, 0.015), calls=[("ledger", "/entries"), ("billing", "/charge")])
      PY
      cat > /obs/apps/billing.py <<'PY'
      """billing — charges the card, then records the payment with ledger."""
      from mesh import serve
      serve("billing", work=(0.25, 0.35), calls=[("ledger", "/entries")])
      PY
      cat > /obs/apps/ledger.py <<'PY'
      """ledger — the system of record."""
      from mesh import serve
      serve("ledger", work=(0.003, 0.008))
      PY
      cat > /obs/answers/bottleneck.txt <<'TXT'
      # The call that makes orders slow. '#' starts a comment.
      edge: ?     # client -> server, as the service graph names them, e.g. shop -> checkout
      metric: ?   # one PromQL query over the service graph's metrics that shows it
      TXT
      app_down loadgen
      for a in ledger billing checkout shop; do app_restart "$a"; app_up "$a"; done
      echo "scenario ready: shop takes orders and calls checkout; checkout calls ledger and billing;"
      echo "billing calls ledger. Every service sends its spans to the Collector (/obs/otel/collector.yaml)."
      echo "How long each service takes, counting everything it waits for:"
      echo "  curl -s 'http://tempo:3200/api/search?q={kind=server}&limit=20' | jq -r '.traces[] | \"\\(.rootServiceName) \\(.durationMs)ms\"'"
      echo "Your answer: /obs/answers/bottleneck.txt"

  verify_done:
    timeout_seconds: 180
    run: |
      . /usr/local/lib/obs.sh
      obs_require_loaded || exit 1
      collector_settle || exit 1
      python3 - <<'PY'
      import json, re, sys, time, urllib.parse, urllib.request

      PROM = "http://prometheus:9090"
      EDGES = [("shop", "checkout"), ("checkout", "ledger"), ("checkout", "billing"), ("billing", "ledger")]
      ANSWER = "/obs/answers/bottleneck.txt"

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
              return get(f"{PROM}/api/v1/query", query=expr)
          except urllib.error.HTTPError as e:
              return json.load(e)
          except OSError as e:
              no(f"Prometheus did not answer ({e}).")

      def names():
          r = q('group by (__name__) ({client!="", server!=""})').get("data", {}).get("result", [])
          return sorted({x["metric"]["__name__"] for x in r})

      deadline = time.time() + 100
      while True:
          total = next((n for n in names() if re.search(r"service_graph_request_total$", n)), None)
          edges = set()
          if total:
              edges = {(x["metric"]["client"], x["metric"]["server"])
                       for x in q(f"sum by (client, server) ({total})")["data"]["result"]}
          if all(e in edges for e in EDGES) or time.time() > deadline:
              break
          time.sleep(5)

      if not total:
          cfg = open("/obs/otel/collector.yaml").read()
          if "servicegraph" not in cfg:
              no("the Collector has no servicegraph connector, and Prometheus has no edges between",
                 "services. See /obs/otel/collector.yaml.")
          targets = get(f"{PROM}/api/v1/targets")["data"]["activeTargets"]
          coll = [t for t in targets if t.get("scrapeUrl", "").startswith("http://collector:")]
          if not coll:
              no("Prometheus scrapes nothing on the Collector, so the edges the connector builds stay",
                 "there. Add a scrape job for the Collector's prometheus exporter.")
          down = [t for t in coll if t["health"] != "up"]
          if down:
              no(f"Prometheus cannot scrape {down[0]['scrapeUrl']}: {down[0].get('lastError') or down[0]['health']}.")
          if all(":8888" in t["scrapeUrl"] for t in coll):
              no("Prometheus scrapes the Collector on :8888, its own telemetry. The connector's",
                 "metrics leave through an exporter in a metrics pipeline, on a port of their own.")
          no(f"Prometheus scrapes {', '.join(t['scrapeUrl'] for t in coll)} and has no service-graph",
             "edges after 100s. servicegraph has to be an exporter of the traces pipeline and a",
             "receiver of a metrics pipeline whose exporter Prometheus scrapes; its",
             "metrics_flush_interval decides how soon they show up (the default is 60s).")
      missing = [f"{c} -> {s}" for c, s in EDGES if (c, s) not in edges]
      if missing:
          no(f"the service graph in Prometheus is missing {', '.join(missing)}. Every call in the",
             "system is an edge; is every span reaching the connector?")

      base = re.sub(r"_total$", "", total)
      hist = next((n for n in names() if n.startswith(base + "_server") and n.endswith("_bucket")), None)
      if not hist:
          no(f"Prometheus has {total} and no server-latency histogram next to it.")
      # A rate needs two scrapes of a series, so a fresh edge has no p95 yet.
      deadline = time.time() + 60
      while True:
          p95 = {}
          for x in q(f"histogram_quantile(0.95, sum by (client, server, le) (rate({hist}[1m])))")["data"]["result"]:
              v = float(x["value"][1])
              if v == v:
                  p95[(x["metric"]["client"], x["metric"]["server"])] = v * (1000 if "milli" not in hist else 1)
          if all(e in p95 for e in EDGES) or time.time() > deadline:
              break
          time.sleep(5)
      ms = lambda e: f"{p95.get(e, float('nan')):.0f}ms"

      def field(k):
          try:
              for line in open(ANSWER):
                  m = re.match(rf"\s*{k}\s*:\s*(.*)", line)
                  if m:
                      return re.sub(r"\s+#.*$", "", m.group(1)).strip()
          except OSError:
              no(f"{ANSWER} is missing. Reset the lesson to get the template back.")
          return ""

      edge = field("edge").lower()
      if not edge or edge == "?":
          no(f"edge in {ANSWER} is not filled in.")
      parts = [p for p in re.split(r"\s*(?:->|→|=>|,|\s)\s*", edge) if p]
      if len(parts) != 2:
          if len(parts) == 1 and parts[0] in ("shop", "checkout", "billing", "ledger"):
              no(f"edge is '{edge}', a service. The answer is a call between two services: which",
                 "service's call to which other service is slow?")
          no(f"edge is '{edge}'. Write it as client -> server, for example shop -> checkout.")
      e = tuple(parts)
      if e not in EDGES:
          no(f"edge is '{edge}', and there is no such call in the service graph: the edges are",
             ", ".join(f"{c} -> {s}" for c, s in EDGES) + ".")
      if e == ("shop", "checkout"):
          no(f"shop -> checkout is the slowest edge (p95 {ms(e)}), and it measures checkout's whole",
             "request, including the time checkout spends waiting on ledger and billing. Which of",
             "checkout's own calls takes that long?")
      if e[1] == "ledger":
          no(f"{e[0]} -> ledger answers at p95 {ms(e)}. ledger is called on every order, twice; that",
             "makes it busy, not slow.")

      metric = field("metric")
      if not metric or metric == "?":
          no(f"metric in {ANSWER} is not filled in: one PromQL query that shows checkout -> billing is",
             "where the time goes.")
      r = q(metric)
      if r.get("status") != "success":
          no(f"Prometheus rejects the metric query: {r.get('error')}")
      if not re.search(r"service_graph", metric) or not re.search(r"(seconds|milliseconds|_server|_client)", metric):
          no("the metric query does not use the service graph's latency histogram. A request count",
             "shows where traffic goes, not where time goes.")
      res = r["data"]["result"] if r["data"]["resultType"] == "vector" else []
      if not any(x["metric"].get("client") == "checkout" and x["metric"].get("server") == "billing" for x in res):
          no("the metric query returns no series labelled client=\"checkout\", server=\"billing\". Keep",
             "the edge's labels in the result, so it says which call it is about.")
      # The answer has to be a time: near the edge's real p95 once scaled by the
      # unit in its name, and longer than billing -> ledger's.
      scale = 1 if "milli" in metric else 1000
      def val(c, s):
          return [float(x["value"][1]) * scale for x in res
                  if x["metric"].get("client") == c and x["metric"].get("server") == s]
      cb, bl, true_cb = val("checkout", "billing"), val("billing", "ledger"), p95.get(("checkout", "billing"), 0)
      if len(cb) != 1 or not (0.25 * true_cb <= cb[0] <= 2 * true_cb):
          no(f"the metric query returns {', '.join(f'{v / scale:g}' for v in cb)} for checkout -> billing, which",
             f"is not its latency (p95 is about {true_cb:.0f}ms). A count or a raw bucket shows traffic,",
             "not time: ask for a quantile of the server-latency histogram, or its _sum over _count.")
      if bl and not cb[0] > max(bl):
          no("the metric query has billing -> ledger as slow as checkout -> billing, so it does not",
             "show where the time goes.")
      print(f"PASS — the service graph has all four edges, and checkout -> billing (p95 {ms(('checkout', 'billing'))})")
      print(f"is the slow call: billing -> ledger answers in {ms(('billing', 'ledger'))}, so the time is billing's own.")
      PY
---
