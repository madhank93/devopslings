---
kind: lesson
title: "ledger returns 500s, and every one of its spans says OK"
description: |
  Support has a list of orders whose payment entry failed with a 500. Tempo
  has a span for every one of them, and every span has status OK, so a
  search for errors finds nothing and the error rate built from spans is
  zero. Make a failed entry look failed in its trace, with the exception
  that failed it.
name: span-status-and-errors
slug: span-status-and-errors
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
      cat > /obs/apps/ledger.py <<'PY'
      """ledger — records payment entries. POST /entries on :8080, with a JSON body:

          {"order_id": "ord-1234", "amount": 42.5, "currency": "EUR"}

      201 when the entry is recorded, 500 when it cannot be.
      """
      import json
      import time
      from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

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

      CURRENCIES = {"EUR", "USD", "GBP"}
      ENTRIES = []


      class LedgerError(Exception):
          """An entry the books cannot take."""


      def record(entry):
          if entry.get("currency") not in CURRENCIES:
              raise LedgerError(f"no account for currency {entry.get('currency')!r}")
          if float(entry.get("amount", 0)) <= 0:
              raise ValueError(f"amount must be positive, got {entry.get('amount')!r}")
          time.sleep(0.01)
          ENTRIES.append(entry)


      class Handler(BaseHTTPRequestHandler):
          def log_message(self, *a):
              pass

          def do_POST(self):
              entry = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0) or 0)) or b"{}")
              ctx = propagate.extract(self.headers)
              with tracer.start_as_current_span("POST /entries", context=ctx, kind=trace.SpanKind.SERVER) as span:
                  span.set_attribute("order.id", str(entry.get("order_id", "")))
                  try:
                      record(entry)
                      code = 201
                  except Exception as e:
                      print(f"ledger: entry {entry.get('order_id')} failed: {type(e).__name__}: {e}", flush=True)
                      code = 500
                  span.set_attribute("http.response.status_code", code)
              self.send_response(code)
              self.send_header("Content-Length", "0")
              self.end_headers()


      ThreadingHTTPServer.daemon_threads = True
      ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
      PY
      app_up ledger
      echo "scenario ready: ledger answers POST http://ledger:8080/entries; some entries fail with 500."
      echo "  curl -s -XPOST ledger:8080/entries -d '{\"order_id\":\"ord-2\",\"amount\":5,\"currency\":\"JPY\"}' -w '%{http_code}\n'"
      echo "  curl -s 'http://tempo:3200/api/search' -G --data-urlencode 'q={resource.service.name=\"ledger\" && status=error}' | jq '.traces | length'"
      echo "The source is /obs/apps/ledger.py; saving it restarts ledger. Its log: /obs/logs/ledger.log"

  verify_done:
    timeout_seconds: 120
    run: |
      python3 - <<'PY'
      import json, random, sys, time, urllib.error, urllib.parse, urllib.request

      TEMPO = "http://tempo:3200"

      def no(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print(l)
          sys.exit(1)

      def get(url):
          with urllib.request.urlopen(url, timeout=10) as r:
              return json.load(r)

      def search(q, since):
          p = urllib.parse.urlencode({"q": q, "start": since, "end": int(time.time()) + 1, "limit": 200, "spss": 1})
          try:
              return get(f"{TEMPO}/api/search?{p}").get("traces", [])
          except OSError as e:
              no(f"Tempo did not answer a search ({e}).")

      def spans(trace_id):
          t = get(f"{TEMPO}/api/traces/{trace_id}")
          return [s for b in t.get("batches") or [] for ss in b.get("scopeSpans") or [] for s in ss.get("spans", [])]

      def log_tail(n=4):
          try:
              lines = [l.rstrip() for l in open("/obs/logs/ledger.log") if not l.startswith("[supervise]")]
          except OSError:
              lines = []
          return ["  " + l[:200] for l in lines[-n:]] or ["  (nothing)"]

      time.sleep(1.5)
      try:
          started = int(open("/obs/run/ledger.started").read())
      except (OSError, ValueError):
          started = 0
      time.sleep(max(0, started + 2 - time.time()))
      since = int(time.time()) - 1
      run = f"chk{random.randrange(16**6):06x}"

      # 24 entries: 4 in a currency ledger has no account for, 3 with a bad amount.
      plan = ["ok"] * 17 + ["currency"] * 4 + ["amount"] * 3
      random.shuffle(plan)
      fails = 0
      for i, kind in enumerate(plan):
          entry = {"order_id": f"{run}-{i}", "amount": round(random.uniform(5, 500), 2), "currency": "EUR"}
          if kind == "currency":
              entry["currency"] = random.choice(["JPY", "CHF", "XYZ"])
          elif kind == "amount":
              entry["amount"] = -entry["amount"]
          req = urllib.request.Request("http://ledger:8080/entries", data=json.dumps(entry).encode(),
                                       headers={"Content-Type": "application/json"})
          try:
              code = urllib.request.urlopen(req, timeout=5).status
          except urllib.error.HTTPError as e:
              code = e.code
          except OSError as e:
              no(f"ledger did not answer POST /entries for a {kind} entry ({e}). An exception that",
                 "escapes do_POST drops the connection instead of answering 500. The end of",
                 "/obs/logs/ledger.log:", *log_tail())
          if code != (201 if kind == "ok" else 500):
              no(f"ledger answered {code} for a {'valid' if kind == 'ok' else 'bad'} entry. Leave the responses",
                 "as they were: 201 for a recorded entry, 500 for one that failed.")
          fails += kind != "ok"

      base = f'resource.service.name="ledger" && name="POST /entries" && span.order.id=~"{run}-.*"'
      found = []
      for _ in range(30):
          time.sleep(1)
          found = search("{" + base + "}", since)
          if len(found) >= len(plan):
              break
      if len(found) < len(plan):
          no(f"the check sent {len(plan)} entries and Tempo has {len(found)} 'POST /entries' spans for them",
             "after 30s. The end of /obs/logs/ledger.log:", *log_tail())

      errors = search("{" + base + " && status=error}", since)
      if len(errors) > fails:
          no(f"{len(errors)} of the check's {len(plan)} spans have status error, and only {fails} requests",
             "failed. Set the error status where the exception is caught, not on every span.")
      if not errors:
          failed = search("{" + base + " && span.http.response.status_code=500}", since)
          probe = (failed or found)[0]["traceID"]
          if any(e.get("name") == "exception" for s in spans(probe) for e in s.get("events", [])):
              no(f"the failed entries' spans carry an exception event and their status is still unset. An",
                 "event is a note on the span; {status=error} and every error rate read the status.",
                 "Set it as well.")
          no(f"{fails} of the check's entries failed with 500 and none of their spans has status error.",
             "Printing the exception writes a log line; the span it happened in never hears of it.")
      if len(errors) < fails:
          no(f"{fails} of the check's entries failed and only {len(errors)} of their spans have status error.",
             "Both kinds of failure have to mark the span: an unknown currency and a bad amount.")

      for t in errors:
          ss = [s for s in spans(t["traceID"]) if s.get("name") == "POST /entries"]
          exc = [e for s in ss for e in s.get("events", []) if e.get("name") == "exception"]
          if not exc:
              no(f"trace {t['traceID']} has status error and no exception event. The status says that it",
                 "failed; record the exception on the span as well, so the trace says why.")
          attrs = {a["key"]: a["value"].get("stringValue", "") for a in exc[0].get("attributes", [])}
          if not attrs.get("exception.type") or not attrs.get("exception.message"):
              no(f"the exception event in trace {t['traceID']} has no exception.type or exception.message.",
                 "Pass the exception object itself; the SDK takes both from it.")
          if attrs["exception.type"].rsplit(".", 1)[-1] not in ("LedgerError", "ValueError"):
              no(f"the exception event in trace {t['traceID']} is a {attrs['exception.type']}, and the",
                 "entry failed with LedgerError or ValueError. Record the exception record() raised.")
      print(f"PASS — {fails} of the check's {len(plan)} entries failed with 500, and exactly those {fails}")
      print("spans have status error, each with an exception event naming its type and message.")
      PY
---
