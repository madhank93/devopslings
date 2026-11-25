---
kind: lesson
title: "checkout's p99 doubled overnight"
description: |
  checkout's p99 has doubled and the on-call wants to restart it. The cause
  is one of five, drawn at random each time you start this drill. Work it
  the way the module taught: service map, span metrics, an exemplar trace, a
  profile. Fix it where it lives, get p99 back under budget, and write down
  the evidence at each step and how you would have been told sooner.
name: apm-triage-drill
slug: apm-triage-drill
createdAt: "2026-11-22"
timingSensitive: true

sandbox:
  stack: obs-stack
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 240
    run: |
      obs-reset >/dev/null
      . /usr/local/lib/obs.sh
      g=/var/lib/devopslings/apm-triage-drill
      rm -rf "$g"; mkdir -p "$g"
      causes="n-plus-one pool regex retry-storm lock"
      n=$(od -An -N2 -tu2 < /dev/urandom | tr -d ' ')
      cause=$(echo "$causes" | cut -d' ' -f$(( n % 5 + 1 )))
      echo "$cause" > "$g/cause"

      cat > /obs/apps/drill.py <<'PY'
      """drill — tracing, profiling and HTTP plumbing shared by checkout, pricing
      and ledger. Spans go to the Collector; CPU profiles go to Pyroscope, linked
      to the spans that were running."""
      import json, urllib.request
      from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

      import pyroscope
      from opentelemetry import propagate, trace
      from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
      from opentelemetry.sdk.resources import Resource
      from opentelemetry.sdk.trace import TracerProvider
      from opentelemetry.sdk.trace.export import BatchSpanProcessor
      from pyroscope.otel import PyroscopeSpanProcessor


      def setup(name):
          pyroscope.configure(application_name=name, server_address="http://pyroscope:4040")
          provider = TracerProvider(resource=Resource.create({"service.name": name}))
          provider.add_span_processor(PyroscopeSpanProcessor())
          provider.add_span_processor(BatchSpanProcessor(
              OTLPSpanExporter(endpoint="http://collector:4318/v1/traces"), schedule_delay_millis=500))
          trace.set_tracer_provider(provider)
          return trace.get_tracer(name)


      def call(tracer, method, url, payload=None, timeout=2.0):
          with tracer.start_as_current_span(f"{method} {url.split(':8080')[1].split('?')[0]}",
                                            kind=trace.SpanKind.CLIENT):
              headers = {"Content-Type": "application/json"}
              propagate.inject(headers)
              data = json.dumps(payload).encode() if payload is not None else None
              req = urllib.request.Request(url, data=data, headers=headers, method=method)
              with urllib.request.urlopen(req, timeout=timeout) as r:
                  return json.load(r)


      def serve(tracer, routes):
          """routes: {(method, path): fn(query, body) -> dict}"""
          class Handler(BaseHTTPRequestHandler):
              def log_message(self, *a):
                  pass

              def handle_one(self, method):
                  path, _, query = self.path.partition("?")
                  fn = routes.get((method, path))
                  body = self.rfile.read(int(self.headers.get("Content-Length", 0) or 0))
                  if not fn:
                      self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers(); return
                  with tracer.start_as_current_span(f"{method} {path}", context=propagate.extract(self.headers),
                                                    kind=trace.SpanKind.SERVER):
                      out = json.dumps(fn(query, json.loads(body) if body else None)).encode()
                  self.send_response(200)
                  self.send_header("Content-Type", "application/json")
                  self.send_header("Content-Length", str(len(out)))
                  self.end_headers()
                  self.wfile.write(out)

              def do_GET(self):
                  self.handle_one("GET")

              def do_POST(self):
                  self.handle_one("POST")

          ThreadingHTTPServer.daemon_threads = True
          ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
      PY

      python3 - "$cause" <<'PY'
      import sys, textwrap
      cause = sys.argv[1]
      bug = lambda c, bad, good: bad if cause == c else good

      open("/obs/apps/ledger.py", "w").write(f'''"""ledger — prices and the order book. GET /prices?skus=a,b,c and POST /entries
      on :8080. Every request holds a database connection from the pool while it works."""
      import threading, time
      from drill import serve, setup

      tracer = setup("ledger")
      POOL = threading.BoundedSemaphore({bug("pool", 1, 16)})   # database connections


      def prices(query, body):
          skus = query.split("=", 1)[1].split(",") if "=" in query else []
          with POOL:
              time.sleep(0.008 + 0.0004 * len(skus))
          return {{s: 100 + len(s) for s in skus}}


      def entries(query, body):
          with POOL:
              time.sleep(0.025)
          return {{"ok": True}}


      serve(tracer, {{("GET", "/prices"): prices, ("POST", "/entries"): entries}})
      ''')

      lookup = bug("n-plus-one",
                   '''    prices = {}
          for sku in skus:
              prices.update(call(tracer, "GET", f"http://ledger:8080/prices?skus={sku}"))''',
                   '''    prices = call(tracer, "GET", "http://ledger:8080/prices?skus=" + ",".join(skus))''')
      open("/obs/apps/fulfil.py", "w").write(f'''"""pricing — quotes an order. POST /quote on :8080 (this container is
      fulfil; the service is pricing). Four workers: a quote is CPU work."""
      import threading, time
      from drill import call, serve, setup

      tracer = setup("pricing")
      WORKERS = threading.BoundedSemaphore(4)


      def quote(query, body):
          skus = body["skus"]
          if not WORKERS.acquire(timeout=1.0):   # the caller gave up on this quote long ago
              return {{"error": "busy"}}
          try:
      {textwrap.indent(lookup, "    ")}
              time.sleep(0.012)
          finally:
              WORKERS.release()
          return {{"total": sum(prices.values())}}


      serve(tracer, {{("POST", "/quote"): quote}})
      ''')

      validate = bug("regex", r'r"([a-z0-9]+\.?)*[a-z0-9]+@shop\.example"', r'r"[^@\s]+@[^@\s]+"')
      retry = bug("retry-storm", "timeout=0.02, attempts=8", "timeout=1.0, attempts=2")
      record = bug("lock",
                   '''        with LEDGER:   # keeps the order book's entries in order
                  call(tracer, "POST", "http://ledger:8080/entries", {"order": n})''',
                   '''        call(tracer, "POST", "http://ledger:8080/entries", {"order": n})''')
      open("/obs/apps/checkout.py", "w").write(f'''"""checkout — takes orders: validates the customer's email, gets a quote
      from pricing (fulfil:8080), records the order with ledger. Customers are
      simulated in-process: about thirty a second arrive, and one
      who has waited behind 64 open orders goes elsewhere."""
      import random, re, threading, time
      from drill import call, setup
      from opentelemetry import trace

      tracer = setup("checkout")
      EMAIL = re.compile({validate})
      LEDGER = threading.Lock()


      def get_quote(skus, timeout=1.0, attempts=2):
          for attempt in range(attempts):
              try:
                  return call(tracer, "POST", "http://fulfil:8080/quote", {{"skus": skus}}, timeout=timeout)
              except OSError:
                  if attempt == attempts - 1:
                      raise


      def take_order(n):
          with tracer.start_as_current_span("POST /checkout", kind=trace.SpanKind.SERVER):
              email = random.choice(["ana", "ben.okafor", "chen.li.93", "dee"]) + "@shop.example"
              if random.random() < 0.2:
                  email = "x" * random.randint(18, 21) + "!@shop.example"
              with tracer.start_as_current_span("validate email"):
                  EMAIL.fullmatch(email)
              skus = [f"sku-{{random.randint(1, 999)}}" for _ in range(random.randint(8, 14))]
              get_quote(skus, {retry})
      {record}


      OPEN = threading.BoundedSemaphore(64)


      def customer(n):
          try:
              take_order(n)
          except Exception as e:
              print(f"order failed: {{e}}", flush=True)
          finally:
              OPEN.release()


      n = 0
      while True:
          n += 1
          if OPEN.acquire(blocking=False):
              threading.Thread(target=customer, args=(n,), daemon=True).start()
          time.sleep(random.expovariate(30))
      ''')
      PY

      cat > /obs/otel/collector.yaml <<'YML'
      # The OpenTelemetry Collector. Saving this file restarts it; its output is in
      # /obs/logs/collector.log. Spans become RED metrics (spanmetrics, with
      # exemplars) and a service graph (servicegraph), scraped by Prometheus.
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
        spanmetrics:
          metrics_flush_interval: 5s
          exemplars:
            enabled: true
        servicegraph:
          metrics_flush_interval: 5s

      exporters:
        otlphttp/tempo:
          endpoint: http://tempo:4318
        prometheus:
          endpoint: 0.0.0.0:8889
          enable_open_metrics: true

      service:
        pipelines:
          traces:
            receivers: [otlp]
            processors: [batch]
            exporters: [otlphttp/tempo, spanmetrics, servicegraph]
          metrics:
            receivers: [spanmetrics, servicegraph]
            exporters: [prometheus]
      YML
      cat >> /obs/prometheus/prometheus.yml <<'YML'

        - job_name: spans
          static_configs:
            - targets: ["collector:8889"]
      YML
      obs_reload >/dev/null
      cat > /obs/answers/triage.md <<'TXT'
      # The triage. '#' starts a comment.
      cause: ?          # one of: n-plus-one, pool, regex, retry-storm, lock
      service: ?        # the service the cause lives in: checkout, pricing or ledger
      service_map: ?    # what the service graph showed, and which edge
      spanmetrics: ?    # what the span metrics showed
      exemplar: ?       # the ID of one slow checkout trace you read
      profile: ?        # what the profile showed (or why it showed nothing)
      detect: ?         # a PromQL query over the span metrics or service graph that would have caught it
      threshold: ?      # the value of that query that should page
      TXT
      for a in ledger fulfil checkout; do app_up "$a"; done
      collector_settle >/dev/null || true
      echo "scenario ready: checkout takes orders, about thirty a second: it validates the email,"
      echo "asks pricing (fulfil:8080) for a quote, and records the order with ledger. Its p99 has doubled."
      echo "Budget: p99 under 150ms. Spans: Tempo. RED and the service graph: Prometheus (job spans)."
      echo "Profiles: Pyroscope (http://pyroscope:4040). Source: /obs/apps/. Your triage: /obs/answers/triage.md"

  verify_done:
    timeout_seconds: 180
    run: |
      . /usr/local/lib/obs.sh
      collector_settle || exit 1
      python3 - <<'PY'
      import json, re, sys, time, urllib.parse, urllib.request

      G = "/var/lib/devopslings/apm-triage-drill"
      ANSWER = "/obs/answers/triage.md"
      BUDGET_MS = 150
      TEMPO, PROM = "http://tempo:3200", "http://prometheus:9090"

      def no(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print(l)
          sys.exit(1)

      def get(url, **params):
          with urllib.request.urlopen(f"{url}?{urllib.parse.urlencode(params)}" if params else url, timeout=15) as r:
              return json.load(r)

      def started(app):
          try:
              return int(open(f"/obs/run/{app}.started").read())
          except (OSError, ValueError):
              return 0

      def tail(path):
          try:
              return open(path, errors="replace").readlines()[-3:]
          except OSError:
              return ["(no log)"]

      try:
          cause = open(f"{G}/cause").read().strip()
      except OSError:
          no("the scenario's record is missing. Reset the lesson.")
      where = {"n-plus-one": "pricing", "pool": "ledger", "regex": "checkout", "retry-storm": "checkout", "lock": "checkout"}

      def field(k):
          try:
              for line in open(ANSWER):
                  m = re.match(rf"\s*{k}\s*:\s*(.*)", line)
                  if m:
                      return re.sub(r"\s+#.*$", "", m.group(1)).strip()
          except OSError:
              no(f"{ANSWER} is missing. Reset the lesson to get the template back.")
          return ""
      for k in ("cause", "service", "service_map", "spanmetrics", "exemplar", "profile", "detect", "threshold"):
          if field(k) in ("", "?"):
              no(f"{k} in {ANSWER} is not filled in.")

      said = field("cause").lower()
      if said not in where:
          no(f"cause is '{said}'. It is one of: {', '.join(where)}.")
      if said != cause:
          no(f"cause is {said}, and the evidence in this run points elsewhere. Go back over the four",
             "steps: which edge is slow, what the slow trace spends its time on, what the profile says.")
      if field("service").lower() != where[cause]:
          no(f"service is '{field('service')}'. Where does the {cause} live?")

      # The fix, measured on orders taken after the last restart of any app.
      time.sleep(1.5)
      since = max(started(a) for a in ("checkout", "fulfil", "ledger")) + 5
      time.sleep(max(0, since + 30 - time.time()))
      until = int(time.time()) - 4

      def search(q, spss=3):
          p = urllib.parse.urlencode({"q": q, "start": since, "end": until, "limit": 2000, "spss": spss})
          try:
              return get(f"{TEMPO}/api/search?{p}").get("traces", [])
          except OSError as e:
              no(f"Tempo did not answer a search ({e}).")

      roots = search('{resource.service.name="checkout" && name="POST /checkout"}')
      if len(roots) < 50:
          no(f"Tempo has {len(roots)} orders from the last 30s; checkout should take about thirty a second.",
             "Is it running? The end of /obs/logs/checkout.log:",
             *["  " + l.rstrip()[:200] for l in tail("/obs/logs/checkout.log")])
      ds = sorted(t["durationMs"] for t in roots if "durationMs" in t)
      p99 = ds[min(len(ds) - 1, int(len(ds) * 0.99))]
      if p99 > BUDGET_MS:
          no(f"checkout's p99 over the last 30s is {p99}ms, over the {BUDGET_MS}ms budget. Restarting or",
             f"adding replicas leaves the {cause} where it is; fix it in {where[cause]}'s code.")

      failed = search('{resource.service.name="checkout" && name="POST /checkout" && status=error}')
      if len(failed) > len(roots) * 0.01:
          no(f"{len(failed)} of the {len(roots)} orders in the last 30s failed. A fast failure is still a lost",
             "order; p99 counts only because the orders behind it succeed. The end of /obs/logs/checkout.log:",
             *["  " + l.rstrip()[:200] for l in tail("/obs/logs/checkout.log")])

      # The cause itself gone, not only diluted.
      src = {a: open(f"/obs/apps/{f}.py").read() for a, f in (("checkout", "checkout"), ("pricing", "fulfil"), ("ledger", "ledger"))}
      if cause == "pool":
          m = re.search(r"BoundedSemaphore\((\d+)\)", src["ledger"])
          if not m or int(m.group(1)) < 8:
              no("ledger's connection pool is still smaller than its concurrent requests.")
      if cause == "n-plus-one":
          per = [len(s) for t in search('{resource.service.name="pricing" && kind=client}', spss=100)
                 for s in [[x for ss in t.get("spanSets", []) for x in ss.get("spans", [])]]]
          if per and max(per) > 2:
              no(f"a single quote still makes {max(per)} calls to ledger. One call for the whole order.")
      if cause == "regex":
          v = sorted(int(s["durationNanos"]) / 1e6 for t in search('{resource.service.name="checkout" && name="validate email"}')
                     for ss in t.get("spanSets", []) for s in ss.get("spans", []))
          if v and v[int(len(v) * 0.99) - 1] > 2:
              no(f"validate email still takes up to {v[-1]:.0f}ms of CPU on some addresses.")
      if cause == "retry-storm":
          per = [len([x for ss in t.get("spanSets", []) for x in ss.get("spans", [])])
                 for t in search('{resource.service.name="pricing" && kind=server}', spss=20)]
          if per and sum(per) / len(per) > 1.5:
              no(f"pricing still serves {sum(per) / len(per):.1f} quotes per order: checkout's retries fire",
                 "before pricing could have answered.")
      if cause == "lock" and re.search(r"with\s+LEDGER\s*:", src["checkout"]):
          no("checkout still holds a process-wide lock across its call to ledger.")

      # The evidence.
      ex = field("exemplar").lower()
      try:
          t = get(f"{TEMPO}/api/traces/{ex}")
          spans = [s for b in t.get("batches", []) for ss in b.get("scopeSpans", []) for s in ss.get("spans", [])]
          root = next(s for s in spans if s["name"] == "POST /checkout")
          dur = (int(root["endTimeUnixNano"]) - int(root["startTimeUnixNano"])) / 1e6
      except (OSError, StopIteration, KeyError, ValueError):
          no(f"exemplar '{ex}' is not a checkout trace in Tempo. Paste the ID of a slow one you opened.")
      if dur < BUDGET_MS:
          no(f"exemplar {ex} took {dur:.0f}ms, inside the budget: it is not one of the slow orders.")
      if cause == "regex" and not re.search(r"validat|regex|re\.|fullmatch|email", field("profile").lower()):
          no("profile does not name what checkout's CPU was spent on. The flame graph names the function.")
      for k in ("service_map", "spanmetrics", "profile"):
          if len(field(k).split()) < 5:
              no(f"{k} is '{field(k)}'. Say what that step showed, in a sentence.")
      q = field("detect")
      try:
          r = get(f"{PROM}/api/v1/query", query=q)
      except urllib.error.HTTPError as e:
          no(f"Prometheus rejects detect: {json.load(e).get('error')}")
      if not re.search(r"traces_(span_metrics|service_graph)_", q):
          no("detect does not use the span metrics or the service graph, which is where this showed first.")
      if not r["data"]["result"]:
          no("detect returns nothing on the metrics Prometheus has: a query with no series never fires.")
      if not re.search(r"\d", field("threshold")):
          no(f"threshold is '{field('threshold')}'. It is a number the detect query crosses.")
      print(f"PASS — {cause} in {where[cause]}, fixed where it lives; p99 {p99}ms under the {BUDGET_MS}ms budget,")
      print("with evidence from each step and a detection signal.")
      PY
---
