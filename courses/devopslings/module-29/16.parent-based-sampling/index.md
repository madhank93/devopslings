---
kind: lesson
title: "Tempo is full of ledger spans with no order above them"
description: |
  checkout traces one order in five, and ledger, which checkout calls for
  every order, picks its own half. Tempo now holds ledger spans whose order
  was never traced, and nobody can tell a lost root from a sampled-away one.
  Make every stored trace whole.
name: parent-based-sampling
slug: parent-based-sampling
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
      """checkout — takes orders and records each one with ledger.

      Customers are simulated in-process: an order every few hundred
      milliseconds. checkout decides which orders are traced: one in five.
      """
      import json
      import random
      import time
      import urllib.request

      from opentelemetry import propagate, trace
      from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
      from opentelemetry.sdk.resources import Resource
      from opentelemetry.sdk.trace import TracerProvider
      from opentelemetry.sdk.trace.export import BatchSpanProcessor
      from opentelemetry.sdk.trace.sampling import ParentBased, TraceIdRatioBased

      provider = TracerProvider(resource=Resource.create({"service.name": "checkout"}),
                                sampler=ParentBased(TraceIdRatioBased(0.2)))
      provider.add_span_processor(BatchSpanProcessor(
          OTLPSpanExporter(endpoint="http://tempo:4318/v1/traces"), schedule_delay_millis=500))
      trace.set_tracer_provider(provider)
      tracer = trace.get_tracer("checkout")


      def take_order(n):
          with tracer.start_as_current_span("POST /checkout", kind=trace.SpanKind.SERVER) as span:
              span.set_attribute("order.id", f"ord-{n}")
              time.sleep(random.uniform(0.01, 0.03))
              with tracer.start_as_current_span("POST /entries", kind=trace.SpanKind.CLIENT):
                  headers = {"Content-Type": "application/json"}
                  propagate.inject(headers)
                  req = urllib.request.Request("http://ledger:8080/entries",
                                               data=json.dumps({"order_id": f"ord-{n}"}).encode(),
                                               headers=headers)
                  urllib.request.urlopen(req, timeout=2).read()


      n = int(time.time()) % 100000 * 100
      while True:
          n += 1
          try:
              take_order(n)
          except Exception as e:
              print(f"order {n} failed: {e}", flush=True)
              time.sleep(1)
          time.sleep(random.uniform(0.1, 0.2))
      PY
      cat > /obs/apps/ledger.py <<'PY'
      """ledger — records orders. POST /entries on :8080.

      Traced at half its requests, to keep ledger's share of the trace bill down.
      """
      import time
      from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

      from opentelemetry import propagate, trace
      from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
      from opentelemetry.sdk.resources import Resource
      from opentelemetry.sdk.trace import TracerProvider
      from opentelemetry.sdk.trace.export import BatchSpanProcessor
      from opentelemetry.sdk.trace.sampling import TraceIdRatioBased

      provider = TracerProvider(resource=Resource.create({"service.name": "ledger"}),
                                sampler=TraceIdRatioBased(0.5))
      provider.add_span_processor(BatchSpanProcessor(
          OTLPSpanExporter(endpoint="http://tempo:4318/v1/traces"), schedule_delay_millis=500))
      trace.set_tracer_provider(provider)
      tracer = trace.get_tracer("ledger")


      class Handler(BaseHTTPRequestHandler):
          def log_message(self, *a):
              pass

          def do_POST(self):
              self.rfile.read(int(self.headers.get("Content-Length", 0)))
              ctx = propagate.extract(self.headers)
              with tracer.start_as_current_span("POST /entries", context=ctx, kind=trace.SpanKind.SERVER):
                  time.sleep(0.01)
              self.send_response(201)
              self.send_header("Content-Length", "0")
              self.end_headers()


      ThreadingHTTPServer.daemon_threads = True
      ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
      PY
      for a in ledger checkout; do app_up "$a"; done
      echo "scenario ready: checkout takes an order every ~150ms, traces one in five, and records"
      echo "each order with ledger. ledger traces half its requests. Both send spans to Tempo."
      echo "Traces whose root never arrived:"
      echo "  curl -s 'http://tempo:3200/api/search?q={resource.service.name=\"ledger\"}&limit=10' | jq '.traces[].rootServiceName'"

  verify_done:
    timeout_seconds: 150
    run: |
      python3 - <<'PY'
      import json, os, sys, time, urllib.error, urllib.parse, urllib.request

      TEMPO = "http://tempo:3200"
      PROBE = "d0d0d0d0"  # first hex digits of the check's own trace ids

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

      def search(q, since, until):
          p = urllib.parse.urlencode({"q": q, "start": since, "end": until, "limit": 500})
          try:
              return [t for t in get(f"{TEMPO}/api/search?{p}").get("traces", [])
                      if not t["traceID"].rjust(32, "0").startswith(PROBE)]
          except OSError as e:
              no(f"Tempo did not answer a search ({e}).")

      def tail(path):
          try:
              return open(path, errors="replace").readlines()[-3:]
          except OSError:
              return ["(no log)"]

      time.sleep(1.5)
      since = max(started("checkout"), started("ledger")) + 3
      # A short window keeps both searches under Tempo's 500-trace limit.
      since = max(since, int(time.time()) - 30)
      time.sleep(max(0, since + 25 - time.time()))
      until = int(time.time()) - 5

      led = search('{resource.service.name="ledger"}', since, until)
      chk = search('{resource.service.name="checkout" && name="POST /checkout"}', since, until)
      if len(chk) < 5:
          no(f"Tempo holds {len(chk)} checkout traces from the last {until - since}s; checkout traces",
             "about one order in five, so there should be a dozen or more. Is it running? The end of",
             "/obs/logs/checkout.log:", *["  " + l.rstrip()[:200] for l in tail("/obs/logs/checkout.log")])
      orphans = [t for t in led if t.get("rootServiceName") != "checkout"]
      if orphans:
          no(f"{len(orphans)} of the {len(led)} traces with a ledger span in them have no checkout span",
             f"above it (rootServiceName {orphans[0].get('rootServiceName')!r}). ledger kept spans of",
             "orders checkout chose not to trace: its decision is still its own.")
      def whole(tid):
          # ledger's span arrived, or checkout's call to ledger failed: an order
          # ledger never answered (it was restarting) says nothing of its sampler.
          try:
              t = get(f"{TEMPO}/api/traces/{tid}")
          except OSError:
              return False
          for s in (s for b in t.get("batches", []) for ss in b.get("scopeSpans", []) for s in ss.get("spans", [])):
              if s.get("kind") == "SPAN_KIND_SERVER" and s.get("name") == "POST /entries":
                  return True
              if s.get("kind") == "SPAN_KIND_CLIENT" and s.get("status", {}).get("code") == "STATUS_CODE_ERROR":
                  return True
          return False

      ids = {t["traceID"] for t in led}
      partial = [t for t in chk if t["traceID"] not in ids]
      # ledger's spans can reach Tempo after the search: re-read before blaming it.
      deadline = time.time() + 15
      while partial:
          partial = [t for t in partial if not whole(t["traceID"])]
          if not partial or time.time() > deadline:
              break
          time.sleep(2)
      if partial:
          no(f"{len(partial)} of the {len(chk)} orders checkout traced have no ledger span in them",
             f"(trace {partial[0]['traceID']}). ledger dropped spans of requests whose caller",
             "kept the trace: a whole trace needs every service to keep what the root kept.")

      # The live ratios can line up by accident. A sampled parent ledger's own
      # ratio would drop, and an unsampled one it would keep, settle whose
      # decision ledger follows.
      def call(tid, flags):
          req = urllib.request.Request("http://ledger:8080/entries", data=b"{}", headers={
              "Content-Type": "application/json", "traceparent": f"00-{tid}-{os.urandom(8).hex()}-{flags}"})
          try:
              urllib.request.urlopen(req, timeout=5).read()
          except OSError as e:
              no(f"ledger did not answer a request from the check ({e}).")

      kept = PROBE + os.urandom(4).hex() + "ffffffffffffff" + os.urandom(1).hex()
      dropped = PROBE + os.urandom(4).hex() + "00000000000000" + "01"
      call(kept, "01")
      call(dropped, "00")
      time.sleep(6)

      def stored(tid):
          try:
              get(f"{TEMPO}/api/traces/{tid}")
              return True
          except urllib.error.HTTPError as e:
              if e.code == 404:
                  return False
              no(f"Tempo answered {e.code} for trace {tid}.")
          except OSError as e:
              no(f"Tempo did not answer ({e}).")

      if not stored(kept):
          no("the check called ledger with a traceparent marked sampled (flags 01), and ledger",
             "did not keep the span. Its own ratio decided, and that ratio happens to agree with",
             "checkout's today; change either one and the traces break again. ledger's sampler has",
             "to follow the parent's decision when there is a parent.")
      if stored(dropped):
          no("the check called ledger with a traceparent marked not sampled (flags 00), and ledger",
             "kept the span: an orphan with no root. When the caller decided not to trace a",
             "request, ledger has to agree.")
      print(f"PASS — {len(chk)} orders traced, each whole with its ledger span, and no ledger span")
      print("without its order. ledger follows the caller's sampled flag both ways.")
      PY
---
