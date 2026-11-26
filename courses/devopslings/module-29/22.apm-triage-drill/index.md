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
      chmod 600 "$g/cause"

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
                  try:
                      with tracer.start_as_current_span(f"{method} {path}", context=propagate.extract(self.headers),
                                                        kind=trace.SpanKind.SERVER):
                          out, code = json.dumps(fn(query, json.loads(body) if body else None)).encode(), 200
                  except Exception as e:
                      print(f"{method} {path} failed: {e!r}", flush=True)
                      out, code = json.dumps({"error": str(e)}).encode(), 500
                  self.send_response(code)
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
      on :8080, each holding a database connection from the pool while it works.
      POST /recorded answers which of the given orders are in the book, at what total."""
      import collections, threading, time
      from drill import serve, setup

      tracer = setup("ledger")
      POOL = threading.BoundedSemaphore({bug("pool", 1, 16)})   # database connections
      BOOK = collections.OrderedDict()   # order -> total; the newest 20,000 orders


      def prices(query, body):
          skus = query.split("=", 1)[1].split(",") if "=" in query else []
          with POOL:
              time.sleep(0.008 + 0.0004 * len(skus))
          return {{s: 100 + len(s) for s in skus}}


      def entries(query, body):
          with POOL:
              time.sleep(0.025)
              BOOK[body["order"]] = body["total"]
          if len(BOOK) > 20000:
              BOOK.popitem(last=False)
          return {{"ok": True}}


      def recorded(query, body):
          return {{o: BOOK[o] for o in body["orders"] if o in BOOK}}


      serve(tracer, {{("GET", "/prices"): prices, ("POST", "/entries"): entries, ("POST", "/recorded"): recorded}})
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
          if not WORKERS.acquire(timeout=1.0):
              raise RuntimeError("busy: this quote waited over 1s for a worker; its caller has given up")
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
                   '''    with LEDGER:   # keeps the order book's entries in order
              call(tracer, "POST", "http://ledger:8080/entries", {"order": body["order"], "total": total})''',
                   '''    call(tracer, "POST", "http://ledger:8080/entries", {"order": body["order"], "total": total})''')
      open("/obs/apps/checkout.py", "w").write(f'''"""checkout — takes orders on :8080 (POST /checkout; the customers are
      /obs/apps/lab.py): validates the customer's email, gets a quote from pricing
      (fulfil:8080), records the order with ledger."""
      import re, threading
      from drill import call, serve, setup

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


      def checkout(query, body):
          with tracer.start_as_current_span("validate email"):
              EMAIL.fullmatch(body["email"])
          total = get_quote(body["skus"], {retry})["total"]
      {record}
          return {{"order": body["order"], "total": total}}


      serve(tracer, {{("POST", "/checkout"): checkout}})
      ''')
      PY

      cat > /obs/apps/lab.py <<'PY'
      """lab — checkout's customers. About thirty a second each place an order;
      one who finds 64 orders already open goes elsewhere."""
      import json, random, threading, time, urllib.request

      OPEN = threading.BoundedSemaphore(64)


      def order(n):
          try:
              email = random.choice(["ana", "ben.okafor", "chen.li.93", "dee"]) + "@shop.example"
              if random.random() < 0.2:
                  email = "x" * random.randint(18, 21) + "!@shop.example"
              skus = [f"sku-{i}" for i in random.sample(range(1, 1000), random.randint(8, 14))]
              body = json.dumps({"order": f"c{n}", "email": email, "skus": skus}).encode()
              req = urllib.request.Request("http://checkout:8080/checkout", body, {"Content-Type": "application/json"})
              urllib.request.urlopen(req, timeout=5).read()
          except Exception as e:
              print(f"order c{n} failed: {e}", flush=True)
          finally:
              OPEN.release()


      n = 0
      while True:
          n += 1
          if OPEN.acquire(blocking=False):
              threading.Thread(target=order, args=(n,), daemon=True).start()
          time.sleep(random.expovariate(30))
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
      for a in ledger fulfil checkout lab; do app_up "$a"; done
      collector_settle >/dev/null || true
      echo "scenario ready: checkout takes orders from its customers (lab), about thirty a second: it validates the email,"
      echo "asks pricing (fulfil:8080) for a quote, and records the order with ledger. Its p99 has doubled."
      echo "Budget: p99 under 150ms. Spans: Tempo. RED and the service graph: Prometheus (job spans)."
      echo "Profiles: Pyroscope (http://pyroscope:4040). Source: /obs/apps/. Your triage: /obs/answers/triage.md"

  verify_done:
    timeout_seconds: 180
    run: |
      . /usr/local/lib/obs.sh
      if ! out=$(collector_settle); then
        printf '%s\n' "${out:-not yet: the Collector will not stay up with /obs/otel/collector.yaml; see /obs/logs/collector.log.}"
        exit 1
      fi
      python3 - <<'PY'
      import ast, collections, json, os, random, re, sys, threading, time, urllib.error, urllib.parse, urllib.request

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

      def post(url, body, timeout):
          req = urllib.request.Request(url, json.dumps(body).encode(), {"Content-Type": "application/json"})
          with urllib.request.urlopen(req, timeout=timeout) as r:
              return json.load(r)

      def tail(path):
          try:
              return ["  " + l.rstrip()[:200] for l in open(path, errors="replace").readlines()[-3:]]
          except OSError:
              return ["  (no log)"]

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

      # The fix, measured on the grader's own orders once every app has settled
      # after its last restart. lab's customers pause meanwhile, so the arrival
      # rate is the grader's alone.
      time.sleep(1.5)
      for app in ("checkout", "fulfil", "ledger"):
          try:
              int(open(f"/obs/run/{app}.started").read())
          except (OSError, ValueError):
              no(f"{app} has not started: /obs/run/{app}.started is missing. Reset the lesson.")
      since = max(int(open(f"/obs/run/{a}.started").read()) for a in ("checkout", "fulfil", "ledger"))
      time.sleep(max(0, since + 3 - time.time()))

      RATE, SECONDS, OPEN_CAP, TIMEOUT = 30, 30, 64, 5
      run = f"v{int(time.time())}"
      orders, threads = [], []
      slots = threading.BoundedSemaphore(OPEN_CAP)

      def place(o):
          t0 = time.monotonic()
          try:
              r = post("http://checkout:8080/checkout", {k: o[k] for k in ("order", "email", "skus")}, TIMEOUT)
              o["ok"] = r.get("total") == o["total"]
              if not o["ok"]:
                  o["err"] = "checkout answered, but not with the order's total"
          except urllib.error.HTTPError as e:
              o["err"] = f"HTTP {e.code} {e.read()[:100].decode(errors='replace')}"
          except Exception as e:
              o["err"] = f"{type(e).__name__}: {e}"[:120]
          finally:
              o["ms"] = (time.monotonic() - t0) * 1000
              slots.release()

      open("/obs/run/lab.down", "w").close()
      time.sleep(2.5)
      try:
          start = time.time()
          while time.time() < start + SECONDS:
              email = random.choice(["ana", "ben.okafor", "chen.li.93", "dee"]) + "@shop.example"
              if random.random() < 0.2:
                  email = "x" * random.randint(18, 21) + "!@shop.example"
              skus = [f"sku-{i}" for i in random.sample(range(1, 1000), random.randint(8, 14))]
              o = {"order": f"{run}-{len(orders)}", "email": email, "skus": skus,
                   "total": sum(100 + len(s) for s in skus), "ok": False, "ms": None, "err": ""}
              orders.append(o)
              if slots.acquire(blocking=False):
                  threads.append(threading.Thread(target=place, args=(o,), daemon=True))
                  threads[-1].start()
              else:
                  o["err"] = f"turned away: {OPEN_CAP} orders already open"
              time.sleep(random.expovariate(RATE))
          end = time.time()
          for t in threads:
              t.join(timeout=max(0.1, end + TIMEOUT + 1 - time.time()))
      finally:
          try:
              os.remove("/obs/run/lab.down")
          except OSError:
              pass

      answered = [o for o in orders if o["ok"]]
      try:
          book = post("http://ledger:8080/recorded", {"orders": [o["order"] for o in answered]}, 15)
      except Exception as e:
          no(f"ledger did not answer POST /recorded ({e}), so which orders it recorded is unknown.",
             "The end of /obs/logs/ledger.log:", *tail("/obs/logs/ledger.log"))
      for o in answered:
          if book.get(o["order"]) != o["total"]:
              o["ok"] = False
              o["err"] = "checkout answered, but ledger has no entry for the order at its total"

      ms = sorted(o["ms"] if o["ms"] is not None else float("inf") for o in orders)
      p99 = ms[min(len(ms) - 1, int(len(ms) * 0.99))]
      if p99 > BUDGET_MS:
          shown = f"{p99:.0f}ms" if p99 != float("inf") else "unbounded (orders turned away)"
          no(f"checkout's p99 over the grader's {len(orders)} orders is {shown}, over the {BUDGET_MS}ms budget.",
             f"Restarting or adding replicas leaves the {cause} where it is; fix it in {where[cause]}'s code.")
      failed = [o for o in orders if not o["ok"]]
      if len(failed) > len(orders) * 0.01:
          no(f"{len(failed)} of the grader's {len(orders)} orders failed. A fast failure is still a lost order;",
             "an order counts when checkout answers with its total and ledger has it recorded. The commonest:",
             *[f"  {n} x {err}" for err, n in collections.Counter(o["err"] for o in failed).most_common(3)])

      # The cause itself gone, not only diluted. Spans from the grader's orders.
      time.sleep(max(0, end + 6 - time.time()))

      def search(q, spss=3):
          p = urllib.parse.urlencode({"q": q, "start": int(start), "end": int(end) + 1, "limit": 2000, "spss": spss})
          try:
              return get(f"{TEMPO}/api/search?{p}").get("traces", [])
          except OSError as e:
              no(f"Tempo did not answer a search ({e}).")

      src = {a: open(f"/obs/apps/{f}.py").read() for a, f in (("checkout", "checkout"), ("pricing", "fulfil"), ("ledger", "ledger"))}
      if cause == "pool":
          m = re.search(r"Semaphore\(\s*(\d+)\s*\)", src["ledger"])
          if not m:
              no("ledger no longer has a connection pool (a Semaphore of a number of connections). A database",
                 "takes only so many connections at once; size the pool, don't remove it.")
          if int(m.group(1)) < 16:
              no(f"ledger's connection pool is {m.group(1)}. At a burst its callers have more requests in flight",
                 "than that (pricing's four workers alone take four); size it for them, 16 or more.")
      if cause == "n-plus-one":
          per = [len(s) for t in search('{resource.service.name="pricing" && kind=client}', spss=100)
                 for s in [[x for ss in t.get("spanSets", []) for x in ss.get("spans", [])]]]
          if not per:
              no("Tempo has no spans for pricing's calls to ledger during the grader's orders. pricing still",
                 "needs ledger's prices; keep the lookup going through call(), which traces it.")
          if max(per) > 2:
              no(f"a single quote still makes {max(per)} calls to ledger. One call for the whole order.")
      if cause == "regex":
          v = sorted(int(s["durationNanos"]) / 1e6 for t in search('{resource.service.name="checkout" && name="validate email"}')
                     for ss in t.get("spanSets", []) for s in ss.get("spans", []))
          if not v:
              no("Tempo has no 'validate email' spans during the grader's orders. checkout still has to",
                 "validate the address; fix the pattern, keep the step and its span.")
          if v[int(len(v) * 0.99) - 1] > 2:
              no(f"validate email still takes up to {v[-1]:.0f}ms of CPU on some addresses.")
      if cause == "retry-storm":
          tree, calls, got = ast.parse(src["checkout"]), [], {}
          for node in ast.walk(tree):
              if isinstance(node, ast.FunctionDef) and node.name == "get_quote":
                  params = [a.arg for a in node.args.args]
                  got.update(zip(params[len(params) - len(node.args.defaults):], node.args.defaults))
                  got["params"] = params
              elif isinstance(node, ast.Call) and getattr(node.func, "id", None) == "get_quote":
                  calls.append(node)
          try:
              got.update(zip(got["params"], calls[0].args))
              got.update((k.arg, k.value) for k in calls[0].keywords)
              timeout, attempts = float(ast.literal_eval(got["timeout"])), int(ast.literal_eval(got["attempts"]))
          except (KeyError, IndexError, ValueError, TypeError):
              no("checkout's get_quote no longer has a timeout and attempts the grader can read. Keep them",
                 "as numbers, in the call or as get_quote's defaults.")
          if timeout < 0.1:
              no(f"checkout still gives pricing {timeout}s to answer a quote, less than pricing takes under",
                 "load, so a quote in a queue is asked for again while the first is still waiting.")
          if attempts < 2:
              no("checkout's get_quote makes a single attempt. With retries off, one dropped connection to",
                 "pricing loses the order; keep one retry and give pricing long enough to answer.")
          if attempts > 3:
              no(f"checkout still tries a quote {attempts} times. Under load each retry is another quote pricing",
                 "has to serve; one retry is enough.")
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
      if cause == "regex" and not re.search(r"validat|regex|\bre\.\w|fullmatch|email", field("profile").lower()):
          no("profile does not name what checkout's CPU was spent on. The flame graph names the function.")
      for k in ("service_map", "spanmetrics", "profile"):
          if len(field(k).split()) < 5:
              no(f"{k} is '{field(k)}'. Say what that step showed, in a sentence.")
      q = field("detect")
      try:
          r = get(f"{PROM}/api/v1/query", query=q)
      except urllib.error.HTTPError as e:
          no(f"Prometheus rejects detect: {json.load(e).get('error')}")
      except OSError as e:
          no(f"Prometheus did not answer the detect query ({e}).")
      if not re.search(r"traces_(span_metrics|service_graph)_", q):
          no("detect does not use the span metrics or the service graph, which is where this showed first.")
      if not r["data"]["result"]:
          no("detect returns nothing on the metrics Prometheus has: a query with no series never fires.")
      if not re.search(r"\d", field("threshold")):
          no(f"threshold is '{field('threshold')}'. It is a number the detect query crosses.")
      print(f"PASS — {cause} in {where[cause]}, fixed where it lives; p99 {p99:.0f}ms under the {BUDGET_MS}ms budget")
      print(f"on {len(orders)} orders, {len(failed)} lost, with evidence from each step and a detection signal.")
      PY
---
