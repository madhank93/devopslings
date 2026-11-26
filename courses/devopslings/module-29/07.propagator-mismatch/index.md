---
kind: lesson
title: "checkout speaks B3, fulfil reads traceparent, and every order is two traces"
description: |
  checkout calls fulfil, which calls ledger, all three traced with no code
  by opentelemetry-instrument. Every order arrives in Tempo as two traces:
  checkout alone, and fulfil with ledger. The context is on the call; it is
  in a header fulfil does not read. Make each order one trace again.
name: propagator-mismatch
slug: propagator-mismatch
createdAt: "2026-11-23"

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
      # One launcher per service: re-run the file under opentelemetry-instrument
      # with that service's OTEL_* settings.
      launcher() {
        cat <<PY
      # The platform's launcher: re-run this file under opentelemetry-instrument,
      # which traces Flask and urllib with no code here and sends the spans to the
      # Collector. Settings are the standard OTEL_* environment variables.
      import os
      import sys

      if "OTEL_SERVICE_NAME" not in os.environ:
          os.environ.update(
              OTEL_SERVICE_NAME="$1",
              OTEL_TRACES_EXPORTER="otlp",
              OTEL_EXPORTER_OTLP_PROTOCOL="http/protobuf",
              OTEL_EXPORTER_OTLP_ENDPOINT="http://collector:4318",
              OTEL_METRICS_EXPORTER="none",
              OTEL_LOGS_EXPORTER="none",
              OTEL_BSP_SCHEDULE_DELAY="500",$2
          )
          os.execvp("opentelemetry-instrument", ["opentelemetry-instrument", sys.executable, *sys.argv])

      import logging
      import urllib.request

      from flask import Flask, request

      logging.getLogger("werkzeug").setLevel(logging.WARNING)
      app = Flask(__name__)


      def call(url):
          req = urllib.request.Request(url, data=b"{}", method="POST", headers={"Content-Type": "application/json"})
          urllib.request.urlopen(req, timeout=5).read()

      PY
      }
      { echo '"""checkout — POST /checkout on :8080. Asks fulfil to reserve the order."""'
        launcher checkout '
              # Set when checkout sent its spans to Zipkin, which reads B3.
              OTEL_PROPAGATORS="b3multi",'
        cat <<'PY'
      @app.post("/checkout")
      def checkout():
          call("http://fulfil:8080/reserve")
          return {"status": "placed"}


      app.run(host="0.0.0.0", port=8080, threaded=True)
      PY
      } > /obs/apps/checkout.py
      { echo '"""fulfil — POST /reserve on :8080. Reserves the stock and books it with ledger."""'
        launcher fulfil ''
        cat <<'PY'
      @app.post("/reserve")
      def reserve():
          print(f"[fulfil] {request.method} {request.path} headers: {dict(request.headers)}", flush=True)
          call("http://ledger:8080/entries")
          return {"status": "reserved"}


      app.run(host="0.0.0.0", port=8080, threaded=True)
      PY
      } > /obs/apps/fulfil.py
      { echo '"""ledger — POST /entries on :8080. Records the payment entry."""'
        launcher ledger ''
        cat <<'PY'
      @app.post("/entries")
      def entries():
          print(f"[ledger] {request.method} {request.path} headers: {dict(request.headers)}", flush=True)
          return {"status": "booked"}, 201


      app.run(host="0.0.0.0", port=8080, threaded=True)
      PY
      } > /obs/apps/ledger.py
      for a in ledger fulfil checkout; do app_up "$a"; done
      for _ in $(seq 30); do
        [ "$(curl -s -o /dev/null -w '%{http_code}' -XPOST checkout:8080/checkout)" = 200 ] && break
        sleep 1
      done
      echo "scenario ready: POST http://checkout:8080/checkout calls fulfil, which calls ledger. All three"
      echo "run under opentelemetry-instrument and send spans through the Collector to Tempo."
      echo "  curl -s -XPOST checkout:8080/checkout"
      echo "  curl -s 'http://tempo:3200/api/search' -G --data-urlencode 'q={}' | jq '.traces[] | {rootServiceName, rootTraceName}'"
      echo "fulfil and ledger print the headers of every request they receive in /obs/logs/<name>.log."
      echo "Sources: /obs/apps/{checkout,fulfil,ledger}.py"

  verify_done:
    timeout_seconds: 150
    run: |
      python3 - <<'PY'
      import ast, base64, json, os, re, sys, time, urllib.error, urllib.request

      TEMPO = "http://tempo:3200"
      APPS = ["checkout", "fulfil", "ledger"]
      N = 3

      def no(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print(l)
          sys.exit(1)

      def services(tid):
          try:
              with urllib.request.urlopen(f"{TEMPO}/api/traces/{tid}", timeout=10) as r:
                  t = json.load(r)
          except urllib.error.HTTPError as e:
              if e.code == 404:
                  return set()
              no(f"Tempo answered {e.code} for trace {tid}.")
          except OSError as e:
              no(f"Tempo did not answer ({e}).")
          return {next((a["value"].get("stringValue") for a in b["resource"]["attributes"]
                        if a["key"] == "service.name"), "?") for b in t.get("batches") or []}

      def log_size(app):
          try:
              return os.path.getsize(f"/obs/logs/{app}.log")
          except OSError:
              return 0

      def received(app, offset):
          """The headers of the last request the app logged after offset, lower-cased."""
          try:
              with open(f"/obs/logs/{app}.log") as f:
                  f.seek(offset)
                  lines = [l for l in f if f"[{app}] POST" in l]
          except OSError:
              return None
          if not lines:
              return None
          try:
              return {k.lower(): v for k, v in ast.literal_eval(lines[-1].split("headers: ", 1)[1]).items()}
          except (IndexError, SyntaxError, ValueError):
              return None

      def log_tail(app):
          try:
              lines = [l for l in open(f"/obs/logs/{app}.log") if not l.startswith("[supervise]")]
          except OSError:
              lines = []
          return ["  " + l.rstrip()[:200] for l in lines[-3:]] or ["  (nothing)"]

      def started(app):
          try:
              return int(open(f"/obs/run/{app}.started").read())
          except (OSError, ValueError):
              return 0

      time.sleep(1.5)
      time.sleep(max(0, max(started(a) for a in APPS) + 4 - time.time()))

      seen = {}
      for n in range(N):
          offsets = {a: log_size(a) for a in APPS}
          tid, sid = os.urandom(16).hex(), os.urandom(8).hex()
          # Both formats with the same IDs: checkout joins the check's trace whichever it reads.
          req = urllib.request.Request("http://checkout:8080/checkout", data=b"{}", method="POST", headers={
              "traceparent": f"00-{tid}-{sid}-01",
              "X-B3-TraceId": tid, "X-B3-SpanId": sid, "X-B3-Sampled": "1"})
          try:
              code = urllib.request.urlopen(req, timeout=10).status
          except urllib.error.HTTPError as e:
              code = e.code
          except OSError as e:
              no(f"checkout did not answer POST /checkout ({e}). The end of /obs/logs/checkout.log:",
                 *log_tail("checkout"))
          if code != 200:
              broken = next((a for a in ("ledger", "fulfil") if log_size(a) == offsets[a] or
                             "Traceback" in open(f"/obs/logs/{a}.log").read()[offsets[a]:]), "checkout")
              no(f"POST /checkout answered {code}. The end of /obs/logs/{broken}.log:", *log_tail(broken))
          got = set()
          for _ in range(20):
              time.sleep(1)
              got = services(tid)
              if got >= set(APPS):
                  break
          seen[tid] = (got, {a: received(a, offsets[a]) for a in ("fulfil", "ledger")})

      for tid, (got, hdrs) in seen.items():
          if got >= set(APPS):
              continue
          if "checkout" not in got:
              no(f"checkout's span is not in trace {tid}, which the check started with both a traceparent",
                 "and B3 headers. checkout has to read at least one of the two.")
          for caller, callee in (("checkout", "fulfil"), ("fulfil", "ledger")):
              if callee in got:
                  continue
              h = hdrs[callee]
              if h is None:
                  no(f"{callee} logged no request during the check's call. The end of /obs/logs/{callee}.log:",
                     *log_tail(callee))
              sent = sorted(k for k in h if k == "traceparent" or k.startswith("x-b3-") or k == "b3")
              no(f"{callee}'s spans are not in trace {tid}, which {caller}'s are. {callee} received",
                 f"{', '.join(sent) or 'no trace headers at all'} from {caller}, and started a new trace",
                 "because it does not read that format. The propagators (OTEL_PROPAGATORS) on the two",
                 "sides have to share one.")
          no(f"trace {tid} holds {sorted(got)}, not all three services.")

      # Copying the IDs by hand fixes one hop for one format, and skips the sampling flag and baggage.
      for a in APPS:
          src = open(f"/obs/apps/{a}.py").read()
          m = re.search(r"traceparent|x-b3-", src, re.I)
          if m:
              no(f"each order is one trace, and /obs/apps/{a}.py writes {m.group(0)!r} itself. Set the",
                 "propagator and let the instrumentation read and write the header.")
      print(f"PASS — each of the check's {N} orders is one trace holding checkout, fulfil and ledger, with the")
      print("context carried by a propagator both sides of every call agree on.")
      PY
---
