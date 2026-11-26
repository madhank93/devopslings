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
                  except Exception as e:   # ValueError: the request itself is bad
                      print(f"{method} {path} failed: {e!r}", flush=True)
                      out, code = json.dumps({"error": str(e)}).encode(), 400 if isinstance(e, ValueError) else 500
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
              if not EMAIL.fullmatch(body["email"]):
                  raise ValueError(f"invalid email {{body['email']!r}}")
          total = get_quote(body["skus"], {retry})["total"]
      {record}
          return {{"order": body["order"], "total": total}}


      serve(tracer, {{("POST", "/checkout"): checkout}})
      ''')
      PY

      cat > /obs/apps/lab.py <<'PY'
      """lab — checkout's customers. About thirty a second each place an order;
      one who finds 64 orders already open goes elsewhere."""
      import json, os, random, threading, time, urllib.request

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
          if os.path.exists("/obs/run/lab.down"):   # the grader is placing its own orders
              time.sleep(0.5)
              continue
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
      except PermissionError:
          no(f"the scenario's record {G}/cause is unreadable to this check. Reset the lesson.")
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

      # cause and service are judged before any evidence, so at most fifteen guesses
      # find them; the fix and the evidence are what this drill grades.
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
      since = 0
      for app in ("checkout", "fulfil", "ledger"):
          try:
              since = max(since, int(open(f"/obs/run/{app}.started").read()))
          except (OSError, ValueError):
              no(f"{app} has not started: /obs/run/{app}.started is missing. Reset the lesson.")
      time.sleep(max(0, since + 3 - time.time()))

      RATE, SECONDS, OPEN_CAP, TIMEOUT = 30, 30, 64, 5
      run = f"v{int(time.time())}"
      orders, threads = [], []
      slots = threading.BoundedSemaphore(OPEN_CAP)

      def order(email, oid=None):
          skus = [f"sku-{i}" for i in random.sample(range(1, 1000), random.randint(8, 14))]
          return {"order": f"{run}-{oid or len(orders)}", "email": email, "skus": skus, "total": sum(100 + len(s) for s in skus),
                  "answer": None, "code": None, "ms": None, "err": ""}

      def place(o):
          t0 = time.monotonic()
          try:
              o["answer"] = post("http://checkout:8080/checkout", {k: o[k] for k in ("order", "email", "skus")}, TIMEOUT)
              o["code"] = 200
          except urllib.error.HTTPError as e:
              o["code"], o["err"] = e.code, f"HTTP {e.code} {e.read()[:100].decode(errors='replace')}"
          except Exception as e:
              o["err"] = f"{type(e).__name__}: {e}"[:120]
          finally:
              o["ms"] = (time.monotonic() - t0) * 1000
              slots.release()

      # One customer in five has an address only a loose pattern accepts; checkout
      # may take or refuse those orders. Every other address must go through.
      def odd(o):
          return "!" in o["email"]

      open("/obs/run/lab.down", "w").close()
      time.sleep(2.5)
      try:
          start = time.time()
          while time.time() < start + SECONDS:
              email = random.choice(["ana", "ben.okafor", "chen.li.93", "dee"]) + "@shop.example"
              if random.random() < 0.2:
                  email = "x" * random.randint(18, 21) + "!@shop.example"
              orders.append(order(email))
              if slots.acquire(blocking=False):
                  threads.append(threading.Thread(target=place, args=(orders[-1],), daemon=True))
                  threads[-1].start()
              else:
                  orders[-1]["err"] = f"turned away: {OPEN_CAP} orders already open"
              time.sleep(random.expovariate(RATE))
          end = time.time()
          for t in threads:
              t.join(timeout=max(0.1, end + TIMEOUT + 1 - time.time()))
      finally:
          try:
              os.remove("/obs/run/lab.down")
          except OSError:
              pass

      def recorded(ids):
          try:
              return post("http://ledger:8080/recorded", {"orders": ids}, 15)
          except Exception as e:
              no(f"ledger did not answer POST /recorded ({e}), so which orders it recorded is unknown.",
                 "The end of /obs/logs/ledger.log:", *tail("/obs/logs/ledger.log"))

      ms = sorted(o["ms"] if o["ms"] is not None else float("inf") for o in orders)
      p99 = ms[min(len(ms) - 1, int(len(ms) * 0.99))]
      if p99 > BUDGET_MS:
          shown = f"{p99:.0f}ms" if p99 != float("inf") else "unbounded (orders turned away)"
          no(f"checkout's p99 over the grader's {len(orders)} orders is {shown}, over the {BUDGET_MS}ms budget.",
             f"Restarting or adding replicas leaves the {cause} where it is; fix it in {where[cause]}'s code.")

      # An answered order must be in the book at its total, every one of them; an
      # order with no answer is lost, and a few of those in a thousand are tolerated.
      answered = [o for o in orders if o["code"] == 200]
      book = recorded([o["order"] for o in answered])
      wrong = [o for o in answered if (o["answer"] or {}).get("total") != o["total"] or book.get(o["order"]) != o["total"]]
      if wrong:
          w = wrong[0]
          no(f"{len(wrong)} of the grader's orders were answered as taken but are not in ledger's book at their",
             f"total. Order {w['order']}: checkout answered {json.dumps(w['answer'])[:80]}, ledger has {book.get(w['order'])}",
             f"for a total of {w['total']}. An answered order has to be recorded.")
      lost = [o for o in orders if o["code"] != 200 and not (odd(o) and o["code"] == 400)]
      if len(lost) > len(orders) * 0.01:
          no(f"{len(lost)} of the grader's {len(orders)} orders got no answer or an error. A fast failure is still",
             "a lost order. The commonest:",
             *[f"  {n} x {err}" for err, n in collections.Counter(o["err"] for o in lost).most_common(3)])

      def search(q, spss=3):
          p = urllib.parse.urlencode({"q": q, "start": int(start), "end": int(end) + 1, "limit": 5000, "spss": spss})
          try:
              return get(f"{TEMPO}/api/search?{p}").get("traces", [])
          except (OSError, ValueError) as e:
              no(f"Tempo did not answer a search ({e}).")

      # Spans reach Tempo a few seconds late; wait until it holds the grader's orders.
      roots = []
      while time.time() < end + 40:
          roots = search('{resource.service.name="checkout" && name="POST /checkout"}')
          if len(roots) >= 0.95 * len([o for o in orders if o["code"]]):
              break
          time.sleep(2)
      if len(roots) > 1.2 * len(orders):
          no(f"checkout took {len(roots)} orders while the grader placed {len(orders)}: something else was sending",
             "orders. lab.py stops while /obs/run/lab.down exists; the grader's rate has to be its own.")

      # The cause itself gone, not only diluted.
      src = {a: open(f"/obs/apps/{f}.py").read() for a, f in (("checkout", "checkout"), ("pricing", "fulfil"), ("ledger", "ledger"))}

      def tree_of(app):
          try:
              t = ast.parse(src[app])
          except SyntaxError as e:
              no(f"{app}'s source does not parse ({e}).")
          for n in ast.walk(t):
              for c in ast.iter_child_nodes(n):
                  c.parent = n
          return t

      def consts(t):
          out = {}
          for n in t.body:
              if isinstance(n, ast.Assign) and len(n.targets) == 1 and isinstance(n.targets[0], ast.Name):
                  try:
                      out[n.targets[0].id] = ast.literal_eval(n.value)
                  except (ValueError, TypeError, SyntaxError):
                      pass
          return out

      def value(e, known, scope=None):
          """The literal an expression stands for: a literal, a module constant, or a parameter bound in scope."""
          if isinstance(e, ast.Name) and scope and e.id in scope:
              return value(scope[e.id], known)
          if isinstance(e, ast.Name) and e.id in known:
              return known[e.id]
          return ast.literal_eval(e)

      def ancestors(n):
          while hasattr(n, "parent"):
              n = n.parent
              yield n

      def named(n, name):
          return isinstance(n, ast.Call) and getattr(n.func, "id", getattr(n.func, "attr", None)) == name

      if cause == "pool":
          t = tree_of("ledger")
          pools = [(n.targets[0].id, n.value) for n in t.body if isinstance(n, ast.Assign) and len(n.targets) == 1
                   and isinstance(n.targets[0], ast.Name) and isinstance(n.value, ast.Call)
                   and getattr(n.value.func, "attr", getattr(n.value.func, "id", "")).endswith("Semaphore")]
          if len(pools) != 1 or not pools[0][1].args:
              no("ledger no longer has one connection pool (a Semaphore of a number of connections). A database",
                 "takes only so many connections at once; size the pool, don't remove it.")
          name, ctor = pools[0]
          try:
              size = int(value(ctor.args[0], consts(t)))
          except (ValueError, TypeError):
              no(f"ledger's pool size {ast.unparse(ctor.args[0])} is not a number the grader can read.")
          if size < 16:
              no(f"ledger's connection pool is {size}. At a burst its callers have more requests in flight",
                 "than that (pricing's four workers alone take four); size it for them, 16 or more.")
          if size > 32:
              no(f"ledger's connection pool is {size}. The database behind it takes only so many connections;",
                 "a pool far past ledger's concurrent requests moves the queue into the database. 16 to 32.")
          fns = {n.name: n for n in t.body if isinstance(n, ast.FunctionDef)}
          for fn in ("prices", "entries"):
              if fn not in fns or not any(isinstance(n, ast.With) and any(isinstance(i.context_expr, ast.Name) and
                                          i.context_expr.id == name for i in n.items) for n in ast.walk(fns[fn])):
                  no(f"ledger's {fn} no longer takes a connection from {name}. Every query holds one while it works;",
                     "skipping the pool is the same as removing it.")
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
          bad, good = order("not an address", "bad"), order("chen.li.93@shop.example", "good")
          for o in (bad, good):
              slots.acquire()
              place(o)
          if bad["code"] == 200 or bad["order"] in recorded([bad["order"]]):
              no("checkout took an order for the address 'not an address'. Validation has to refuse what the",
                 "pattern does not match; a faster pattern, not a skipped check.")
          if good["code"] != 200:
              no(f"checkout refused chen.li.93@shop.example ({good['err']}). The pattern has to accept a real address.")
      if cause == "retry-storm":
          t = tree_of("checkout")
          known = consts(t)
          gq = next((n for n in t.body if isinstance(n, ast.FunctionDef) and n.name == "get_quote"), None)
          unreadable = ("checkout's get_quote no longer has the shape the grader reads: one call() to pricing, inside",
                        "one 'for attempt in range(attempts)' loop, with numbers (or constants) for timeout and attempts.")
          if gq is None:
              no(*unreadable)
          params = [a.arg for a in gq.args.args]
          defaults = dict(zip(params[len(params) - len(gq.args.defaults):], gq.args.defaults))
          calls = [n for n in ast.walk(gq) if named(n, "call")]
          loops = [n for n in ast.walk(gq) if isinstance(n, ast.For) and named(n.iter, "range")]
          if len(calls) != 1 or len(loops) != 1:
              no(*unreadable)
          t_expr = next((k.value for k in calls[0].keywords if k.arg == "timeout"),
                        calls[0].args[4] if len(calls[0].args) > 4 else ast.Constant(2.0))
          a_expr = loops[0].iter.args[-1]
          sites = [n for n in ast.walk(t) if named(n, "get_quote")]
          if not sites:
              no(*unreadable)
          for site in sites:
              if any(isinstance(a, (ast.For, ast.While)) for a in ancestors(site)):
                  no("checkout calls get_quote inside a loop: retries on top of get_quote's own retries multiply",
                     "the quotes pricing has to serve. Retry in one place.")
              scope = dict(defaults)
              scope.update(zip(params, site.args))
              scope.update((k.arg, k.value) for k in site.keywords)
              try:
                  timeout, attempts = float(value(t_expr, known, scope)), int(value(a_expr, known, scope))
              except (ValueError, TypeError, KeyError):
                  no(*unreadable)
              if timeout < 0.1:
                  no(f"checkout still gives pricing {timeout}s to answer a quote, less than pricing takes under",
                     "load, so a quote in a queue is asked for again while the first is still waiting.")
              if timeout > 2.0:
                  no(f"checkout gives pricing {timeout}s to answer a quote. A customer will not wait that long, and",
                     "a hung pricing holds every order that long; keep it above pricing's latency, at most 2s.")
              if attempts < 2:
                  no("checkout's get_quote makes a single attempt. With retries off, one dropped connection to",
                     "pricing loses the order; keep one retry and give pricing long enough to answer.")
              if attempts > 3:
                  no(f"checkout still tries a quote {attempts} times. Under load each retry is another quote pricing",
                     "has to serve; one retry is enough.")
      if cause == "lock":
          t = tree_of("checkout")
          for c in (n for n in ast.walk(t) if named(n, "call") and any(isinstance(a, ast.Constant) and "ledger" in str(a.value) for a in n.args)):
              held = [i.context_expr for a in ancestors(c) if isinstance(a, ast.With) for i in a.items
                      if not named(i.context_expr, "start_as_current_span")]
              fn = next((a for a in ancestors(c) if isinstance(a, ast.FunctionDef)), None)
              if held or (fn and any(named(n, "acquire") for n in ast.walk(fn))):
                  what = ast.unparse(held[0]) if held else "an acquire()"
                  no(f"checkout still holds a lock ({what}) across its call to ledger, so orders record one at a time.")

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
      def prom(**params):
          try:
              return get(f"{PROM}/api/v1/query", query=q, **params)
          except urllib.error.HTTPError as e:
              body = e.read().decode(errors="replace")
              try:
                  body = json.loads(body).get("error", body)
              except ValueError:
                  pass
              no(f"Prometheus rejects detect: {body[:200]}")
          except (OSError, ValueError) as e:
              no(f"Prometheus did not answer the detect query ({e}).")
      r = prom()
      if not re.search(r"traces_(span_metrics|service_graph)_", q):
          no("detect does not use the span metrics or the service graph, which is where this showed first.")
      if not r["data"]["result"]:
          no("detect returns nothing on the metrics Prometheus has: a query with no series never fires.")
      m = re.search(r"\d+(\.\d+)?", field("threshold"))
      if not m:
          no(f"threshold is '{field('threshold')}'. It is a number the detect query crosses.")
      # While the exemplar was slow, the query has to have been at or over the
      # threshold, or it would not have paged. No reading then is not held against it.
      at = min(time.time(), int(root["endTimeUnixNano"]) / 1e9 + 30)
      try:
          then = [float(s["value"][1]) for s in prom(time=at)["data"]["result"]]
      except (KeyError, TypeError, ValueError, IndexError):
          then = []
      then = [x for x in then if x == x and x not in (float("inf"), float("-inf"))]
      if then and max(then) < float(m.group()):
          no(f"detect read {max(then):.3g} around your exemplar, while checkout was over budget, which is under",
             f"the threshold {m.group()}: it would not have paged when it mattered.")
      print(f"PASS — {cause} in {where[cause]}, fixed where it lives; p99 {p99:.0f}ms under the {BUDGET_MS}ms budget")
      print(f"on {len(orders)} orders ({len(roots)} in Tempo), {len(lost)} lost, with evidence from each step and a detection signal.")
      PY
---
