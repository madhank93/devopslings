---
kind: lesson
title: "The log says the payment failed, and nothing leads to the request that failed"
description: |
  payments logs every failed charge and traces every request, and the two
  never meet. From a "payment failed" line in Loki the only way to the trace
  is a time window in Tempo, and at this traffic dozens of traces overlap
  it. Put the trace id in every log record, and make Grafana open that exact
  trace from the line.
name: log-to-trace
slug: log-to-trace
createdAt: "2026-11-23"

sandbox:
  stack: obs-stack
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      obs-reset >/dev/null
      . /usr/local/lib/obs.sh
      cat > /obs/apps/lab.py <<'PY'
      """payments — charges cards for orders, four at a time.

      Each request is one trace in Tempo. Logs go straight to Loki, one JSON
      record per line, in the stream {service="payments"}. Saving this file
      restarts it; its own errors are in /obs/logs/lab.log.
      """
      import json
      import logging
      import random
      import threading
      import time
      import urllib.request

      from opentelemetry import trace
      from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
      from opentelemetry.sdk.resources import Resource
      from opentelemetry.sdk.trace import TracerProvider
      from opentelemetry.sdk.trace.export import BatchSpanProcessor

      provider = TracerProvider(resource=Resource.create({"service.name": "payments"}))
      provider.add_span_processor(BatchSpanProcessor(
          OTLPSpanExporter(endpoint="http://tempo:4318/v1/traces"), schedule_delay_millis=500))
      trace.set_tracer_provider(provider)
      tracer = trace.get_tracer("payments")


      class JsonFormatter(logging.Formatter):
          def format(self, record):
              rec = {"ts": self.formatTime(record), "level": record.levelname.lower(),
                     "msg": record.getMessage()}
              rec.update(getattr(record, "fields", {}))
              return json.dumps(rec)


      class LokiHandler(logging.Handler):
          """Pushes each record to Loki as one line, exactly as the formatter wrote it."""

          def emit(self, record):
              body = {"streams": [{"stream": {"service": "payments"},
                                   "values": [[str(int(record.created * 1e9)), self.format(record)]]}]}
              try:
                  urllib.request.urlopen(urllib.request.Request(
                      "http://loki:3100/loki/api/v1/push", data=json.dumps(body).encode(),
                      headers={"Content-Type": "application/json"}), timeout=2).read()
              except Exception:
                  self.handleError(record)


      handler = LokiHandler()
      handler.setFormatter(JsonFormatter())
      log = logging.getLogger("payments")
      log.addHandler(handler)
      log.setLevel(logging.INFO)

      DECLINES = ["card expired", "insufficient funds", "issuer unavailable"]


      def charge(order_id, amount):
          with tracer.start_as_current_span("POST /payments", kind=trace.SpanKind.SERVER) as span:
              span.set_attribute("order.id", order_id)
              log.info("payment requested", extra={"fields": {"order_id": order_id, "amount": amount}})
              with tracer.start_as_current_span("card network authorise") as auth:
                  time.sleep(random.uniform(0.05, 0.4))
                  if random.random() < 0.1:
                      reason = random.choice(DECLINES)
                      auth.set_status(trace.StatusCode.ERROR, reason)
                      span.set_status(trace.StatusCode.ERROR, reason)
                      log.error("payment failed", extra={"fields": {"order_id": order_id, "reason": reason}})
                      return
              log.info("payment captured", extra={"fields": {"order_id": order_id, "amount": amount}})


      def worker(w):
          n = 0
          while True:
              n += 1
              charge(f"ord-{w}{int(time.time()) % 100000:05d}{n % 100:02d}", random.randint(5, 400))
              time.sleep(random.uniform(0.05, 0.2))


      for w in range(1, 4):
          threading.Thread(target=worker, args=(w,), daemon=True).start()
      worker(4)
      PY
      # Grafana reads its datasources from /obs/grafana/provisioning only when
      # told to; put back the baseline ones.
      for _ in $(seq 1 120); do
        curl -sf -u admin:admin -X POST http://grafana:3000/api/admin/provisioning/datasources/reload >/dev/null && break
        sleep 1
      done
      app_up lab
      echo "scenario ready: payments (/obs/apps/lab.py, in the lab container) logs to Loki in"
      echo "{service=\"payments\"} and sends a trace per request to Tempo. Its failures:"
      echo "  logcli query '{service=\"payments\"} |= \"payment failed\"' --since=2m --limit=5"
      echo "Grafana's datasources are in /obs/grafana/provisioning/datasources/; Grafana rereads them on"
      echo "  curl -u admin:admin -X POST http://grafana:3000/api/admin/provisioning/datasources/reload"

  verify_done:
    timeout_seconds: 90
    run: |
      python3 - <<'PY'
      import glob, json, re, sys, time, urllib.parse, urllib.request

      LOKI, TEMPO, GRAFANA = "http://loki:3100", "http://tempo:3200", "http://grafana:3000"

      def no(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print(l)
          sys.exit(1)

      def get(url, auth=False):
          req = urllib.request.Request(url)
          if auth:
              req.add_header("Authorization", "Basic YWRtaW46YWRtaW4=")
          with urllib.request.urlopen(req, timeout=15) as r:
              return json.load(r)

      def tail():
          try:
              lines = [l.rstrip() for l in open("/obs/logs/lab.log") if not l.startswith("[supervise]")]
          except OSError:
              lines = []
          return ["  " + l[:200] for l in lines[-4:]] or ["  (nothing)"]

      # Records from the code as it is now: payments restarts within a second
      # of a save.
      time.sleep(1.5)
      try:
          started = int(open("/obs/run/lab.started").read())
      except (OSError, ValueError):
          started = 0
      time.sleep(max(0, started + 15 - time.time()))
      args = urllib.parse.urlencode({"query": '{service="payments"}', "start": (started + 1) * 10**9,
                                     "end": time.time_ns(), "limit": 5000, "direction": "forward"})
      try:
          body = get(f"{LOKI}/loki/api/v1/query_range?{args}")
      except OSError as e:
          no(f"Loki did not answer ({e}).")
      lines = [l for s in body["data"]["result"] for _, l in s["values"]]
      if len(lines) < 20:
          no(f"payments has sent {len(lines)} records to Loki since it last started. Is it running?",
             "The end of /obs/logs/lab.log:", *tail())

      recs = []
      for l in lines:
          try:
              recs.append((l, json.loads(l)))
          except ValueError:
              no("payments sent a line that is not JSON:", f"  {l[:160]}")
      lacking = [l for l, r in recs if "trace_id" not in r]
      if lacking:
          no(f"{len(lacking)} of {len(recs)} records payments sent since it last started have no trace_id, e.g.:",
             f"  {lacking[0][:160]}")
      for l, r in recs:
          tid = str(r["trace_id"])
          if re.fullmatch(r"0+", tid):
              no("a record carries trace_id " + tid + ":", f"  {l[:160]}",
                 "That is the id of no span: it was read where no span was current.")
          if not re.fullmatch(r"[0-9a-f]{32}", tid):
              hint = ("It is a decimal integer; Tempo and every W3C traceparent write it as 32 hex digits."
                      if tid.isdigit() else "Tempo and every W3C traceparent write a trace id as 32 lower-case hex digits.")
              no(f"a record carries trace_id {tid[:40]}:", f"  {l[:160]}", hint)

      # Each failure's trace_id has to name the request that failed.
      failed = [(l, r) for l, r in recs if r.get("msg") == "payment failed"]
      if not failed:
          no("payments logged no \"payment failed\" since it last started; one in ten payments fails.",
             "Did a change stop it logging those?")

      def spans(tid):
          try:
              t = get(f"{TEMPO}/api/traces/{tid}")
          except urllib.error.HTTPError as e:
              if e.code == 404:
                  return None
              raise
          out = []
          for b in t.get("batches") or t.get("resourceSpans") or []:
              for ss in b.get("scopeSpans") or []:
                  out += ss.get("spans", [])
          return out

      for l, r in failed[-3:]:
          got = None
          for _ in range(8):
              got = spans(r["trace_id"])
              if got:
                  break
              time.sleep(1)
          if not got:
              no(f"Tempo has no trace {r['trace_id']}, the trace_id of", f"  {l[:160]}",
                 "Its spans would have arrived within a second or two. Is the id taken from the span",
                 "that handles the payment, or from one that is never exported?")
          orders = {a["value"].get("stringValue") for s in got for a in s.get("attributes", [])
                    if a["key"] == "order.id"}
          if r.get("order_id") not in orders:
              no(f"trace {r['trace_id']} is not the request that logged", f"  {l[:160]}",
                 f"It is the trace of {', '.join(sorted(o for o in orders if o)) or 'no order'}. Take the trace id from the",
                 "span that is current when the record is logged.")

      # Grafana: a derived field on the Loki datasource that opens that trace.
      try:
          ds = get(f"{GRAFANA}/api/datasources/uid/loki", auth=True)
      except OSError as e:
          no(f"Grafana did not answer ({e}).")
      fields = (ds.get("jsonData") or {}).get("derivedFields") or []
      if not fields:
          on_disk = any("derivedFields" in open(p).read()
                        for p in glob.glob("/obs/grafana/provisioning/datasources/*.y*ml"))
          if on_disk:
              no("the provisioning file has derivedFields, and Grafana's Loki datasource does not.",
                 "Grafana reads provisioning at start and when told to:",
                 "  curl -u admin:admin -X POST http://grafana:3000/api/admin/provisioning/datasources/reload")
          no("Grafana's Loki datasource has no derived field, so a log line in Explore links to nothing.")
      to_tempo = [f for f in fields if f.get("datasourceUid") == "tempo"]
      if not to_tempo:
          no("Grafana's Loki datasource has derived fields, and none opens a trace in Tempo:",
             *[f"  {f.get('name')}: url={f.get('url')!r} datasourceUid={f.get('datasourceUid')!r}" for f in fields],
             "A link inside Grafana names the target datasource by uid; Tempo's is \"tempo\".")
      line, rec = failed[-1]
      problems = []
      for f in to_tempo:
          if f.get("matcherType", "regex") != "regex":
              problems.append(f"{f.get('name')}: matches a label, and the trace id is in the line")
              continue
          try:
              m = re.search(f.get("matcherRegex") or "", line)
          except re.error as e:
              problems.append(f"{f.get('name')}: matcherRegex does not compile ({e})")
              continue
          if not m or not m.groups():
              problems.append(f"{f.get('name')}: matcherRegex {f.get('matcherRegex')!r} has no capture group that matches")
              continue
          value = m.group(1)
          url = (f.get("url") or "").replace("${__value.raw}", value)
          if value != rec["trace_id"]:
              problems.append(f"{f.get('name')}: matcherRegex captures {value[:50]!r}, not the trace id")
          elif not (f.get("url") or "").strip():
              problems.append(f"{f.get('name')}: its url is empty in Grafana. A provisioning file expands $NAME and"
                              " ${NAME} from Grafana's environment; write a literal $ as $$")
          elif url.strip() != rec["trace_id"]:
              problems.append(f"{f.get('name')}: the query it opens in Tempo is {url[:60]!r}; it has to be the trace id, ${{__value.raw}}")
          else:
              print(f"PASS — every payments record carries the trace_id of its request, and Grafana's")
              print(f"derived field `{f.get('name')}` opens trace {value} from")
              print(f"  {line[:120]}")
              sys.exit(0)
      no("Grafana's derived field would not open the trace of this record:", f"  {line[:160]}",
         *["  " + p for p in problems])
      PY
---
