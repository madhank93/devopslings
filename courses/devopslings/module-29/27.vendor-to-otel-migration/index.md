---
kind: lesson
title: "Leaving the vendor without going dark"
description: |
  Every service's traces go to Acme, the APM vendor, and the contract ends
  in ninety days. The new stack is the Collector and Tempo. Plan the move so
  that there is never a day nobody can see production: ship to both, prove
  parity before cutting over, and move the alerts and dashboards without a
  gap. Start the dual-ship today.
name: vendor-to-otel-migration
slug: vendor-to-otel-migration
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
      cat > /obs/apps/billing.py <<'PY'
      """Acme's OTLP intake, as this lab simulates it, on :4318.

        POST /v1/traces   OTLP/HTTP protobuf or JSON, as any vendor intake takes it
        GET  /stats       spans received, by service
      """
      import collections, gzip, json, threading
      from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

      from google.protobuf.json_format import Parse
      from opentelemetry.proto.collector.trace.v1.trace_service_pb2 import ExportTraceServiceRequest

      spans = collections.Counter()
      probes = collections.Counter()
      lock = threading.Lock()


      class Handler(BaseHTTPRequestHandler):
          def log_message(self, *a):
              pass

          def do_POST(self):
              body = self.rfile.read(int(self.headers.get("Content-Length", 0) or 0))
              if self.headers.get("Content-Encoding") == "gzip":
                  body = gzip.decompress(body)
              req = ExportTraceServiceRequest()
              if "json" in self.headers.get("Content-Type", ""):
                  Parse(body, req)
              else:
                  req.ParseFromString(body)
              with lock:
                  for rs in req.resource_spans:
                      svc = next((a.value.string_value for a in rs.resource.attributes if a.key == "service.name"), "?")
                      for ss in rs.scope_spans:
                          for s in ss.spans:
                              spans[svc] += 1
                              for a in s.attributes:
                                  if a.key == "migration.probe":
                                      probes[a.value.string_value] += 1
              out = ExportTraceServiceRequest().SerializeToString()
              self.send_response(200)
              self.send_header("Content-Type", "application/x-protobuf")
              self.send_header("Content-Length", str(len(out)))
              self.end_headers()
              self.wfile.write(out)

          def do_GET(self):
              with lock:
                  if self.path.startswith("/probe/"):
                      body = json.dumps({"spans": probes[self.path[len("/probe/"):]]})
                  else:
                      body = json.dumps({"spans_by_service": dict(spans)})
              self.send_response(200)
              self.send_header("Content-Type", "application/json")
              self.send_header("Content-Length", str(len(body)))
              self.end_headers()
              self.wfile.write(body.encode())


      ThreadingHTTPServer.daemon_threads = True
      ThreadingHTTPServer(("0.0.0.0", 4318), Handler).serve_forever()
      PY
      sed -i 's#http://tempo:4318/v1/traces#http://collector:4318/v1/traces#' /obs/apps/checkout.py /obs/apps/fulfil.py /obs/apps/ledger.py
      cat > /obs/otel/collector.yaml <<'YML'
      # The OpenTelemetry Collector. Saving this file restarts it; its output,
      # including a config it refuses, is in /obs/logs/collector.log.
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

      exporters:
        # Acme's intake. Every dashboard and every alert the on-call relies on
        # reads from Acme. (In this lab the intake runs at billing:4318.)
        otlphttp/acme:
          endpoint: http://billing:4318

      service:
        telemetry:
          metrics:
            readers:
              - pull:
                  exporter:
                    prometheus:
                      host: 0.0.0.0
                      port: 8888
        pipelines:
          traces:
            receivers: [otlp]
            processors: [batch]
            exporters: [otlphttp/acme]
      YML
      rm -rf /obs/migration
      mkdir -p /obs/migration
      cat > /obs/migration/INVENTORY.md <<'MD'
      # What runs on Acme today

      - 40 services. Every one now sends OTLP to the Collector; the Collector sends
        everything to Acme (/obs/otel/collector.yaml).
      - 120 dashboards in Acme's UI, and 65 alerts, 12 of which page the on-call.
      - The new stack is the Collector, Tempo, Prometheus and Grafana, all running.
      - Acme's contract ends in 90 days. Traffic has a weekly shape: a Monday peak
        and a Saturday-night batch run that nothing else exercises.
      MD
      cat > /obs/answers/migration.txt <<'TXT'
      # The migration plan. '#' starts a comment.
      phases: ?            # in order, comma-separated, from: instrument, dual-ship, parity, move-alerts, move-dashboards, cut-over, decommission
      parity_metric: ?     # what you compare between Acme and the new stack before cutting over
      parity_threshold: ?  # how close counts as parity: a number and its unit
      parity_window: ?     # how long parity has to hold before cut-over, e.g. 10 days
      alerts: ?            # how the alerts move without a window where nothing pages
      dashboards: ?        # how the dashboards move
      rollback: ?          # what happens if the new stack misses something after cut-over
      TXT
      for a in ledger fulfil broker checkout billing; do app_up "$a"; done
      collector_settle >/dev/null || true
      echo "scenario ready: services send traces to the Collector, which sends them to Acme only."
      echo "  curl -s billing:4318/stats | jq        # what Acme has received"
      echo "Read /obs/migration/INVENTORY.md; your plan: /obs/answers/migration.txt"

  verify_done:
    timeout_seconds: 120
    run: |
      . /usr/local/lib/obs.sh
      collector_settle || exit 1
      python3 - <<'PY'
      import json, os, re, sys, time, urllib.parse, urllib.request

      ANSWER = "/obs/answers/migration.txt"

      def no(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print(l)
          sys.exit(1)

      def get(url):
          with urllib.request.urlopen(url, timeout=10) as r:
              return json.load(r)

      # Dual-ship: a probe through the Collector has to reach both backends.
      probe = os.urandom(6).hex()
      now = time.time_ns()
      spans = [{"traceId": os.urandom(16).hex(), "spanId": os.urandom(8).hex(), "name": "migration probe", "kind": 2,
                "startTimeUnixNano": str(now), "endTimeUnixNano": str(now + 10**6),
                "attributes": [{"key": "migration.probe", "value": {"stringValue": probe}}]} for _ in range(20)]
      body = json.dumps({"resourceSpans": [{"resource": {"attributes": [
          {"key": "service.name", "value": {"stringValue": "migration-check"}}]},
          "scopeSpans": [{"scope": {"name": "check"}, "spans": spans}]}]}).encode()
      try:
          urllib.request.urlopen(urllib.request.Request("http://collector:4318/v1/traces", data=body,
                                 headers={"Content-Type": "application/json"}), timeout=10).read()
      except OSError as e:
          no(f"the Collector did not take the check's spans on :4318 ({e}).")
      q = urllib.parse.urlencode({"q": f'{{span.migration.probe="{probe}"}}', "limit": 100})
      deadline = time.time() + 30
      while True:
          time.sleep(3)
          try:
              acme = get(f"http://billing:4318/probe/{probe}")["spans"]
          except OSError as e:
              no(f"Acme's intake (billing:4318) did not answer ({e}). Reset the lesson if it is gone.")
          try:
              tempo = len(get(f"http://tempo:3200/api/search?{q}").get("traces", []))
          except OSError as e:
              no(f"Tempo did not answer a search ({e}).")
          if (acme >= 20 and tempo >= 20) or time.time() > deadline:
              break
      if acme < 20 and tempo >= 20:
          no(f"the check's 20 spans reached Tempo and {acme} reached Acme. Every dashboard and alert still",
             "reads from Acme: switching the Collector over is the big-bang cut-over, and from now on",
             "the on-call is paged by nothing. Ship to both.")
      if tempo < 20:
          no(f"the check sent 20 spans through the Collector; Acme received {acme} and Tempo {tempo}.",
             "Dual-shipping means one pipeline exporting to both: add the new stack next to Acme.")

      def field(k):
          try:
              for line in open(ANSWER):
                  m = re.match(rf"\s*{k}\s*:\s*(.*)", line)
                  if m:
                      return re.sub(r"\s+#.*$", "", m.group(1)).strip()
          except OSError:
              no(f"{ANSWER} is missing. Reset the lesson to get the template back.")
          return ""
      for k in ("phases", "parity_metric", "parity_threshold", "parity_window", "alerts", "dashboards", "rollback"):
          if field(k) in ("", "?"):
              no(f"{k} in {ANSWER} is not filled in.")

      known = ["instrument", "dual-ship", "parity", "move-alerts", "move-dashboards", "cut-over", "decommission"]
      phases = [p.strip().lower() for p in field("phases").split(",") if p.strip()]
      for p in phases:
          if p not in known:
              no(f"phases has '{p}'; use the names from the template: {', '.join(known)}.")
      at = {p: i for i, p in enumerate(phases)}
      if "cut-over" not in at:
          no("phases has no cut-over. The plan ends with Acme gone; say when the switch happens.")
      for p in ("dual-ship", "parity", "move-alerts", "move-dashboards"):
          if p not in at or at[p] > at["cut-over"]:
              no(f"{p} does not come before cut-over. Cutting over before it is the big-bang switch: the",
                 {"dual-ship": "day of the switch is the first day the new stack sees production",
                  "parity": "first proof the new stack sees everything Acme does comes after Acme is gone",
                  "move-alerts": "on-call is paged by an empty system until the alerts catch up",
                  "move-dashboards": "on-call opens dashboards that point at a backend with no data"}[p] + ".")
      if at.get("dual-ship", 0) > at.get("parity", 0):
          no("parity comes before dual-ship. There is nothing to compare until both backends get the data.")
      if "decommission" not in at or at["decommission"] < at["cut-over"]:
          no("decommission does not come after cut-over. Acme stays on, receiving, until the new stack",
             "has run alone long enough to trust; that is the rollback path.")

      if not re.search(r"\b(counts?|spans?|traces?|rates?|errors?|latency|p\d\d|percentiles?|volume|series)\b",
                       field("parity_metric").lower()):
          no(f"parity_metric is '{field('parity_metric')}'. Name a number both backends can produce, such as",
             "spans per service per hour, or error rate and p99 per route.")
      if not re.search(r"\d", field("parity_threshold")):
          no(f"parity_threshold is '{field('parity_threshold')}'. Parity is a number you can fail, like 1%.")
      w = field("parity_window").lower()
      m = re.search(r"(\d+(?:\.\d+)?)\s*(days?|d\b|weeks?|w\b|hours?|h\b)", w)
      if not m:
          no(f"parity_window is '{w}'. Give a duration, like 14 days.")
      days = float(m.group(1)) * {"d": 1, "w": 7, "h": 1 / 24}[m.group(2)[0]]
      if days < 7:
          no(f"parity_window is {w}. Traffic has a weekly shape, and the Saturday-night batch only runs",
             "once a week: parity measured over less than a week has never seen it.")
      if not re.search(r"\b(parallel|both|shadow|side[- ]by[- ]side|alongside|dual|compare\w*|duplicate\w*)\b",
                       field("alerts").lower()):
          no(f"alerts is '{field('alerts')}'. Say how they run in both systems, and are compared, before",
             "the pager moves; otherwise there is a window where either both page or neither does.")
      if not re.search(r"\b(rebuil\w*|recreat\w*|port\w*|convert\w*|translat\w*|migrat\w*|side[- ]by[- ]side|compare\w*|both|parallel)\b",
                       field("dashboards").lower()):
          no(f"dashboards is '{field('dashboards')}'. Say how they are rebuilt on the new stack and checked",
             "against Acme's before anyone has to use them.")
      if not re.search(r"\b(acme|vendor)\b", field("rollback").lower()):
          no(f"rollback is '{field('rollback')}'. The rollback is Acme, still receiving until decommission:",
             "say so, and what makes you use it.")
      print(f"PASS — the Collector ships to Acme and Tempo; the plan proves parity over {m.group(0)} before cut-over,")
      print("moves alerts and dashboards first, and keeps Acme as the rollback until decommission.")
      PY
---
