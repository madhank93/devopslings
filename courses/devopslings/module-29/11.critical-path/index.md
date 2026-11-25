---
kind: lesson
title: "The longest span is not why checkout is slow"
description: |
  A checkout trace has forty spans and takes about half a second. The
  longest span in it is the recommendations call, and making it faster
  would change nothing. Find the chain of spans that sets the request's
  latency, predict what fixing it saves, and fix it.
name: critical-path
slug: critical-path
createdAt: "2026-11-23"

sandbox:
  stack: obs-stack
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 150
    run: |
      obs-reset >/dev/null
      mkdir -p /obs/data
      . /usr/local/lib/obs.sh
      cat > /obs/apps/checkout.py <<'PY'
      """checkout — POST /checkout on :8080 builds the order summary page:
      the cart, prices, stock from every warehouse, and recommendations.
      """
      import json
      import threading
      import time
      import urllib.request
      from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

      from opentelemetry import context, propagate, trace
      from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
      from opentelemetry.sdk.resources import Resource
      from opentelemetry.sdk.trace import TracerProvider
      from opentelemetry.sdk.trace.export import BatchSpanProcessor

      provider = TracerProvider(resource=Resource.create({"service.name": "checkout"}))
      provider.add_span_processor(BatchSpanProcessor(
          OTLPSpanExporter(endpoint="http://tempo:4318/v1/traces"), schedule_delay_millis=500))
      trace.set_tracer_provider(provider)
      tracer = trace.get_tracer("checkout")

      WAREHOUSES = [1, 2, 3, 4, 5, 6]


      def in_background(fn, *args):
          """Run fn(*args) on a thread, inside the caller's trace context.
          Returns a function that waits for it and gives back its result."""
          ctx, out = context.get_current(), {}

          def run():
              token = context.attach(ctx)
              try:
                  out["value"] = fn(*args)
              finally:
                  context.detach(token)

          t = threading.Thread(target=run)
          t.start()
          return lambda: (t.join(), out.get("value"))[1]


      def step(name, seconds):
          with tracer.start_as_current_span(name):
              time.sleep(seconds)


      def recommendations():
          # The model team's scoring call: ten shards, one after another.
          with tracer.start_as_current_span("recommendations"):
              for shard in range(10):
                  step(f"score shard {shard}", 0.03)
          return ["sku-1", "sku-2"]


      def stock(warehouse):
          with tracer.start_as_current_span("GET /stock", kind=trace.SpanKind.CLIENT) as span:
              span.set_attribute("warehouse.id", warehouse)
              headers = {}
              propagate.inject(headers)
              req = urllib.request.Request(f"http://ledger:8080/stock?warehouse={warehouse}", headers=headers)
              with urllib.request.urlopen(req, timeout=5) as r:
                  return json.load(r)["available"]


      def summary():
          step("auth", 0.003)
          with tracer.start_as_current_span("load cart"):
              for line in range(8):
                  step("SELECT cart_items", 0.002)
          with tracer.start_as_current_span("price cart"):
              for rule in ("base", "tax", "shipping", "promotions"):
                  step(f"price {rule}", 0.002)
          recs = in_background(recommendations)
          available = sum(stock(w) for w in WAREHOUSES)
          picks = recs()
          step("render", 0.005)
          return {"available": available, "recommended": picks}


      class Handler(BaseHTTPRequestHandler):
          def log_message(self, *a):
              pass

          def do_POST(self):
              self.rfile.read(int(self.headers.get("Content-Length", 0) or 0))
              with tracer.start_as_current_span("POST /checkout", context=propagate.extract(self.headers),
                                                kind=trace.SpanKind.SERVER):
                  body = json.dumps(summary()).encode()
              self.send_response(200)
              self.send_header("Content-Length", str(len(body)))
              self.end_headers()
              self.wfile.write(body)


      ThreadingHTTPServer.daemon_threads = True
      ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
      PY
      cat > /obs/apps/ledger.py <<'PY'
      """ledger — the warehouse stock service, run by the inventory team.
      GET /stock?warehouse=N answers with that warehouse's stock. Each
      warehouse's system answers at its own speed. Not yours to change.
      """
      import json
      import time
      from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
      from urllib.parse import parse_qs, urlparse

      from opentelemetry import propagate, trace
      from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
      from opentelemetry.sdk.resources import Resource
      from opentelemetry.sdk.trace import TracerProvider
      from opentelemetry.sdk.trace.export import BatchSpanProcessor

      provider = TracerProvider(resource=Resource.create({"service.name": "ledger"}))
      provider.add_span_processor(BatchSpanProcessor(
          OTLPSpanExporter(endpoint="http://tempo:4318/v1/traces"), schedule_delay_millis=500))
      trace.set_tracer_provider(provider)
      tracer = trace.get_tracer("ledger")

      LATENCY = {1: 0.070, 2: 0.095, 3: 0.060, 4: 0.085, 5: 0.100, 6: 0.075}


      class Handler(BaseHTTPRequestHandler):
          def log_message(self, *a):
              pass

          def do_GET(self):
              w = int(parse_qs(urlparse(self.path).query).get("warehouse", ["1"])[0])
              with tracer.start_as_current_span("GET /stock", context=propagate.extract(self.headers),
                                                kind=trace.SpanKind.SERVER) as span:
                  span.set_attribute("warehouse.id", w)
                  time.sleep(LATENCY.get(w, 0.05))
              body = json.dumps({"warehouse": w, "available": 10 * w}).encode()
              self.send_response(200)
              self.send_header("Content-Length", str(len(body)))
              self.end_headers()
              self.wfile.write(body)


      ThreadingHTTPServer.daemon_threads = True
      ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
      PY
      cat > /obs/answers/critical-path.txt <<'TXT'
      # '#' starts a comment.
      chain: ?       # the name of the spans that, one after another, set the request's latency
      saving_ms: ?   # how many ms faster POST /checkout gets once that chain runs in parallel
      TXT
      for a in ledger checkout; do app_restart "$a"; app_up "$a"; done
      python3 - <<'PY'
      import statistics, sys, time, urllib.request
      def once():
          t0 = time.monotonic()
          urllib.request.urlopen(urllib.request.Request("http://checkout:8080/checkout", data=b"{}"), timeout=10).read()
          return (time.monotonic() - t0) * 1000
      deadline = time.time() + 60
      while True:
          try:
              once()
              break
          except OSError:
              if time.time() > deadline:
                  sys.exit("checkout did not start")
              time.sleep(1)
      for _ in range(4):
          once()
      ms = statistics.median(once() for _ in range(15))
      open("/obs/data/critical-path.baseline", "w").write(f"{ms:.1f}\n")
      PY
      echo "scenario ready: POST /checkout builds the order summary; it takes about $(cut -d. -f1 /obs/data/critical-path.baseline)ms."
      echo "Its traces:"
      echo "  curl -s -X POST http://checkout:8080/checkout; curl -s 'http://tempo:3200/api/search?q={name=\"POST /checkout\"}&limit=3' | jq -r '.traces[].traceID'"
      echo "Your answer: /obs/answers/critical-path.txt. Source: /obs/apps/checkout.py (ledger.py is another team's)."

  verify_done:
    timeout_seconds: 150
    run: |
      python3 - <<'PY'
      import hashlib, json, os, re, statistics, sys, time, urllib.error, urllib.request

      TEMPO = "http://tempo:3200"
      ANSWER = "/obs/answers/critical-path.txt"
      LEDGER_SHA = "c5b2e04cd0d0a56f1a633e6a31bbe630a0bdfb435db57a3109b6264cabb79f27"

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

      if hashlib.sha256(open("/obs/apps/ledger.py", "rb").read()).hexdigest() != LEDGER_SHA:
          no("/obs/apps/ledger.py has changed. The warehouses answer at their own speed and the",
             "inventory team owns that service; the fix is in how checkout calls it. Reset the lesson,",
             "or put ledger.py back.")
      try:
          base = float(open("/obs/data/critical-path.baseline").read())
      except (OSError, ValueError):
          no("/obs/data/critical-path.baseline, the latency measured when the lesson started, is gone.",
             "Reset the lesson.")

      def field(name):
          try:
              for line in open(ANSWER):
                  m = re.match(rf"\s*{name}\s*:\s*(.*)", line)
                  if m:
                      return re.sub(r"\s+#.*$", "", m.group(1)).strip()
          except OSError:
              no(f"{ANSWER} is missing. Reset the lesson to get the template back.")
          return ""

      chain = field("chain").lower()
      if not chain or chain == "?":
          no(f"chain in {ANSWER} is not filled in.")
      if "recommend" in chain or "shard" in chain:
          no(f"chain is '{field('chain')}'. recommendations is the longest span, and it runs on its own thread",
             "while checkout does something else. Which spans run one after another during it, and take",
             "longer in total?")
      if not re.search(r"\bstock\b", chain):
          no(f"chain is '{field('chain')}'. Which spans run one after another, start to end, for most of",
             "the request?")
      saving = field("saving_ms")
      try:
          predicted = float(saving.lower().removesuffix("ms").strip())
      except ValueError:
          no(f"saving_ms in {ANSWER} is '{saving}'; write a number of milliseconds.")

      def started(app):
          try:
              return int(open(f"/obs/run/{app}.started").read())
          except (OSError, ValueError):
              return 0

      # supervise restarts an edited app within half a second; until then
      # .started still holds the previous start.
      time.sleep(1)
      time.sleep(max(0, max(started("checkout"), started("ledger")) + 3 - time.time()))

      def once(tid=None):
          headers = {"traceparent": f"00-{tid}-{os.urandom(8).hex()}-01"} if tid else {}
          t0 = time.monotonic()
          try:
              body = json.load(urllib.request.urlopen(urllib.request.Request(
                  "http://checkout:8080/checkout", data=b"{}", headers=headers), timeout=10))
          except (OSError, ValueError) as e:
              no(f"POST /checkout failed ({e}). The end of /obs/logs/checkout.log:", *tail("checkout"))
          if not isinstance(body, dict) or body.get("recommended") != ["sku-1", "sku-2"]:
              got = body.get("recommended") if isinstance(body, dict) else body
              no(f"POST /checkout answered recommended={got!r}; it should still carry the",
                 "recommendations, ['sku-1', 'sku-2']. The request has to wait for them.")
          return (time.monotonic() - t0) * 1000

      for _ in range(4):
          once()
      now = statistics.median(once() for _ in range(15))
      if now < 280:
          no(f"POST /checkout now takes {now:.0f}ms, less than the ~300ms recommendations takes on its own:",
             "the response no longer waits for recommendations. It is the model team's call; leave it on",
             "the request.")
      tid = os.urandom(16).hex()
      once(tid)

      deadline = time.time() + 20
      while True:
          try:
              with urllib.request.urlopen(f"{TEMPO}/api/traces/{tid}", timeout=10) as r:
                  spans = [s for b in json.load(r).get("batches", []) for ss in b.get("scopeSpans", [])
                           for s in ss.get("spans", [])]
          except urllib.error.HTTPError as e:
              if e.code != 404:
                  no(f"Tempo answered {e.code} for trace {tid}.")
              spans = []
          except OSError as e:
              no(f"Tempo did not answer ({e}).")
          names = [s["name"] for s in spans]
          if (names.count("GET /stock") >= 12 and "recommendations" in names) or time.time() > deadline:
              break
          time.sleep(2)

      span = lambda s: (int(s["startTimeUnixNano"]) / 1e6, int(s["endTimeUnixNano"]) / 1e6)
      recs = [span(s) for s in spans if s["name"] == "recommendations"]
      stock = sorted(span(s) for s in spans if s["name"] == "GET /stock" and s.get("kind") in ("SPAN_KIND_CLIENT", 3))
      if not recs or len(stock) < 6:
          no(f"trace {tid} has {len(recs)} recommendations span(s) and {len(stock)} GET /stock client spans",
             "after 20s; it should have one and six. A call made on a thread that does not carry the",
             "trace context starts a trace of its own. The end of /obs/logs/checkout.log:", *tail("checkout"))
      if recs[0][1] - recs[0][0] < 280:
          no(f"recommendations took {recs[0][1] - recs[0][0]:.0f}ms in trace {tid}; it took about 300 before.",
             "It is the model team's call and it is not on the critical path: leave it as it was.")
      overlap = sum(1 for a, b in zip(stock, stock[1:]) if b[0] < a[1])
      if overlap < 5:
          no(f"the six GET /stock calls in trace {tid} still run one after another ({overlap} of them",
             "start before the previous one ends). They do not depend on each other.")

      measured = base - now
      tol = max(40.0, 0.2 * measured)
      if abs(predicted - measured) > tol:
          no(f"you predicted saving_ms {predicted:.0f}; the request went from {base:.0f}ms to {now:.0f}ms, a saving",
             f"of {measured:.0f}ms. Once the stock calls run side by side, which branch of the request is",
             "the longest?")
      print(f"PASS — the stock chain was the critical path. POST /checkout went from {base:.0f}ms to {now:.0f}ms,")
      print(f"{measured:.0f}ms faster against the {predicted:.0f}ms you predicted; recommendations now sets the pace.")
      PY
---
