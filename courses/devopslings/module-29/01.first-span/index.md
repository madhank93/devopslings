---
kind: lesson
title: "ledger has the OpenTelemetry SDK installed and has never sent a span"
description: |
  ledger records every order's payment entry. The OpenTelemetry SDK and its
  OTLP exporter are installed in its image, and nothing in its code uses
  them, so Tempo has never heard of it. Create ledger's first span by hand,
  give it the entry's attributes, and get it into Tempo.
name: first-span
slug: first-span
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

      The OpenTelemetry SDK (opentelemetry-sdk) and its OTLP/HTTP exporter
      (opentelemetry-exporter-otlp-proto-http) are installed. Nothing here
      uses them yet.
      """
      import json
      import time
      from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

      ENTRIES = []


      def record(entry):
          """Write one entry to the books."""
          time.sleep(0.01)
          ENTRIES.append(entry)


      class Handler(BaseHTTPRequestHandler):
          def log_message(self, *a):
              pass

          def do_POST(self):
              if self.path != "/entries":
                  self.send_error(404)
                  return
              entry = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0) or 0)) or b"{}")
              record(entry)
              self.send_response(201)
              self.send_header("Content-Length", "0")
              self.end_headers()


      ThreadingHTTPServer.daemon_threads = True
      ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
      PY
      app_up ledger
      echo "scenario ready: ledger answers POST http://ledger:8080/entries and sends nothing to Tempo."
      echo "Try it:"
      echo "  curl -s -XPOST ledger:8080/entries -d '{\"order_id\":\"ord-1\",\"amount\":9.5,\"currency\":\"EUR\"}' -w '%{http_code}\n'"
      echo "The source is /obs/apps/ledger.py; saving it restarts ledger."

  verify_done:
    timeout_seconds: 120
    run: |
      python3 - <<'PY'
      import json, os, random, sys, time, urllib.parse, urllib.request

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
          p = urllib.parse.urlencode({"q": q, "start": since, "end": int(time.time()) + 1, "limit": 20})
          try:
              return get(f"{TEMPO}/api/search?{p}").get("traces", [])
          except OSError as e:
              no(f"Tempo did not answer a search ({e}).")

      def log_size():
          try:
              return os.path.getsize("/obs/logs/ledger.log")
          except OSError:
              return 0

      def log_since(offset):
          try:
              with open("/obs/logs/ledger.log") as f:
                  f.seek(offset)
                  return [l.rstrip() for l in f if not l.startswith("[supervise]")]
          except OSError:
              return []

      def log_tail(n=4):
          return ["  " + l[:200] for l in log_since(max(0, log_size() - 4000))[-n:]] or ["  (nothing)"]

      def spans(trace_id):
          t = get(f"{TEMPO}/api/traces/{trace_id}")
          out = []
          for b in t.get("batches") or t.get("resourceSpans") or []:
              res = {a["key"]: a["value"] for a in b.get("resource", {}).get("attributes", [])}
              for ss in b.get("scopeSpans") or []:
                  for s in ss.get("spans", []):
                      out.append(dict(s, resource=res))
          return out

      time.sleep(1.5)
      try:
          since = int(open("/obs/run/ledger.started").read())
      except (OSError, ValueError):
          since = 0
      time.sleep(max(0, since + 2 - time.time()))
      since = int(time.time()) - 1
      log_start = log_size()

      sent = []
      for _ in range(3):
          entry = {"order_id": f"ord-{random.randrange(10**8):08d}",
                   "amount": round(random.uniform(5, 500), 2), "currency": random.choice(["EUR", "USD", "GBP"])}
          req = urllib.request.Request("http://ledger:8080/entries", data=json.dumps(entry).encode(),
                                       headers={"Content-Type": "application/json"})
          try:
              code = urllib.request.urlopen(req, timeout=5).status
          except OSError as e:
              no(f"ledger did not answer POST /entries ({e}). The end of /obs/logs/ledger.log:", *log_tail())
          if code != 201:
              no(f"ledger answered POST /entries with {code}, not 201. Keep the handler's behaviour as it was.")
          sent.append(entry)

      want = sent[-1]
      found = []
      for _ in range(25):
          time.sleep(1)
          found = search(f'{{name="record entry" && span.order.id="{want["order_id"]}"}}', since)
          if found:
              break
      if not found:
          other = search(f'{{span.order.id="{want["order_id"]}"}}', since)
          if other:
              no(f"a span carries order.id {want['order_id']}, and it is named",
                 f"{other[0].get('rootTraceName')!r}. Name the span 'record entry'.")
          named = search('{name="record entry"}', since)
          if named:
              no("spans named 'record entry' reach Tempo, and none carries the order_id the check sent",
                 f"({want['order_id']}) as the attribute order.id. Set it from the request's body,",
                 "on the span, while the span is open.")
          if any('"name": "record entry"' in l for l in log_since(log_start)):
              no("'record entry' spans are printed in /obs/logs/ledger.log and never reach Tempo.",
                 "A console exporter writes spans to stdout; Tempo needs an OTLP exporter pointed at it",
                 "(http://tempo:4318/v1/traces) or at the Collector (http://collector:4318/v1/traces).")
          no(f"the check sent 3 entries to ledger and no span named 'record entry' with order.id",
             f"{want['order_id']} reached Tempo within 25s. Is a TracerProvider with an OTLP exporter set",
             "up before the span starts? The end of /obs/logs/ledger.log:", *log_tail())

      for entry in sent:
          hit = search(f'{{name="record entry" && span.order.id="{entry["order_id"]}"}}', since)
          if not hit:
              no(f"the span for order {entry['order_id']} did not reach Tempo; the last of the three did.",
                 "Every request has to get its own span.")
          ss = [s for s in spans(hit[0]["traceID"]) if s.get("name") == "record entry"]
          if not ss:
              no(f"Tempo found trace {hit[0]['traceID']} and returned no 'record entry' span in it.",
                 "Give it a few seconds and check again.")
          s = ss[0]
          svc = s["resource"].get("service.name", {}).get("stringValue", "")
          if svc != "ledger":
              no(f"the span arrives with service.name {svc!r}. Without a Resource that names it, the SDK",
                 "reports unknown_service, and nobody can find ledger's spans by service. Give the",
                 "TracerProvider a Resource with service.name ledger.")
          attrs = {a["key"]: a["value"] for a in s.get("attributes", [])}
          amount = attrs.get("entry.amount")
          if amount is None:
              no(f"the span for {entry['order_id']} has no attribute entry.amount. It carries:",
                 "  " + (", ".join(sorted(attrs)) or "(no attributes)"))
          if "stringValue" in amount:
              no(f"entry.amount is the string {amount['stringValue']!r}. Set it as a number, so a query",
                 "like {span.entry.amount > 100} can compare it.")
          got = float(amount.get("doubleValue", amount.get("intValue", "nan")))
          if abs(got - entry["amount"]) > 0.005:
              no(f"entry.amount is {got} on the span for {entry['order_id']}, and that request sent",
                 f"{entry['amount']}. Take it from the request body.")
          cur = attrs.get("entry.currency", {}).get("stringValue")
          if cur != entry["currency"]:
              no(f"entry.currency is {cur!r} on the span for {entry['order_id']}, and that request sent",
                 f"{entry['currency']!r}.")
      print("PASS — each of the check's 3 entries has a 'record entry' span in Tempo, from service")
      print("ledger, carrying the order.id, entry.amount and entry.currency the request sent.")
      PY
---
