---
kind: lesson
title: "Zero-code tracing sees the request and not the job it queued"
description: |
  fulfil runs under opentelemetry-instrument, so every request to it is a
  span without a line of tracing code. The request only queues a job; a
  worker thread does the real work, and that thread shows up nowhere in the
  trace. Give the worker a span, in the request's trace.
name: zero-code-misses-the-queue
slug: zero-code-misses-the-queue
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
      cat > /obs/apps/fulfil.py <<'PY'
      """fulfil — POST /orders on :8080 accepts an order and answers 202 at once.
      A worker thread picks the job off a queue and fulfils it: reserves the
      stock and prints the label, which takes a few hundred milliseconds.
      """
      # The platform's launcher, the same in every service: re-run this file
      # under opentelemetry-instrument, which traces Flask and urllib with no
      # code here and sends the spans to the Collector.
      import os
      import sys

      if "OTEL_SERVICE_NAME" not in os.environ:
          os.environ.update(
              OTEL_SERVICE_NAME="fulfil",
              OTEL_TRACES_EXPORTER="otlp",
              OTEL_EXPORTER_OTLP_PROTOCOL="http/protobuf",
              OTEL_EXPORTER_OTLP_ENDPOINT="http://collector:4318",
              OTEL_METRICS_EXPORTER="none",
              OTEL_LOGS_EXPORTER="none",
              OTEL_BSP_SCHEDULE_DELAY="500",
          )
          os.execvp("opentelemetry-instrument", ["opentelemetry-instrument", sys.executable, *sys.argv])

      import logging
      import queue
      import random
      import threading
      import time
      import uuid

      from flask import Flask, request

      logging.getLogger("werkzeug").setLevel(logging.WARNING)
      app = Flask(__name__)
      JOBS = queue.Queue()


      def reserve_stock(order):
          time.sleep(random.uniform(0.15, 0.2))


      def print_label(order):
          time.sleep(random.uniform(0.15, 0.2))


      def worker():
          while True:
              job = JOBS.get()
              reserve_stock(job["order"])
              print_label(job["order"])
              JOBS.task_done()


      @app.post("/orders")
      def accept():
          job = {"id": uuid.uuid4().hex, "order": request.get_json(silent=True) or {}}
          JOBS.put(job)
          return {"job": job["id"]}, 202


      threading.Thread(target=worker, daemon=True).start()
      app.run(host="0.0.0.0", port=8080, threaded=True)
      PY
      app_up fulfil
      for _ in $(seq 30); do
        [ "$(curl -s -o /dev/null -w '%{http_code}' -XPOST fulfil:8080/orders -H 'Content-Type: application/json' -d '{"sku":"A1"}')" = 202 ] && break
        sleep 1
      done
      echo "scenario ready: fulfil accepts POST http://fulfil:8080/orders with 202 and fulfils the order on"
      echo "a worker thread. Its traces, from opentelemetry-instrument, go through the Collector to Tempo:"
      echo "  curl -s 'http://tempo:3200/api/search' -G --data-urlencode 'q={resource.service.name=\"fulfil\"}' | jq"
      echo "Source: /obs/apps/fulfil.py; output: /obs/logs/fulfil.log"

  verify_done:
    timeout_seconds: 150
    run: |
      python3 - <<'PY'
      import base64, json, os, sys, time, urllib.error, urllib.parse, urllib.request

      TEMPO = "http://tempo:3200"
      SVC = 'resource.service.name="fulfil"'
      N = 5
      JOB = 0.25   # the worker spends 0.3-0.4s on each job

      def no(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print(l)
          sys.exit(1)

      def tempo(path, **params):
          try:
              with urllib.request.urlopen(f"{TEMPO}{path}?{urllib.parse.urlencode(params)}", timeout=10) as r:
                  return json.load(r)
          except urllib.error.HTTPError as e:
              if e.code == 404:
                  return {}
              no(f"Tempo answered {e.code} ({e}).")
          except OSError as e:
              no(f"Tempo did not answer ({e}).")

      def spans(trace_id):
          t = tempo(f"/api/traces/{trace_id}")
          out = []
          for b in t.get("batches") or []:
              for ss in b.get("scopeSpans") or []:
                  scope = ss.get("scope", {}).get("name", "")
                  out += [dict(s, scope=scope) for s in ss.get("spans", [])]
          return out

      def dur(s):
          return (int(s["endTimeUnixNano"]) - int(s["startTimeUnixNano"])) / 1e9

      def log_tail():
          try:
              lines = [l for l in open("/obs/logs/fulfil.log") if not l.startswith("[supervise]")]
          except OSError:
              lines = []
          return ["  " + l.rstrip()[:200] for l in lines[-3:]] or ["  (nothing)"]

      try:
          started = int(open("/obs/run/fulfil.started").read())
      except (OSError, ValueError):
          started = 0
      time.sleep(1.5)
      time.sleep(max(0, started + 4 - time.time()))
      since = int(time.time()) - 1

      traces = []
      for _ in range(N):
          tid, sid = os.urandom(16).hex(), os.urandom(8).hex()
          req = urllib.request.Request("http://fulfil:8080/orders", data=b'{"sku":"A1"}', method="POST",
                                       headers={"Content-Type": "application/json",
                                                "traceparent": f"00-{tid}-{sid}-01"})
          try:
              code = urllib.request.urlopen(req, timeout=5).status
          except urllib.error.HTTPError as e:
              code = e.code
          except OSError as e:
              no(f"fulfil did not answer POST /orders ({e}). The end of /obs/logs/fulfil.log:", *log_tail())
          if code != 202:
              no(f"fulfil answered POST /orders with {code}, not 202. The request should still only queue",
                 "the job. The end of /obs/logs/fulfil.log:", *log_tail())
          traces.append((tid, sid))
          time.sleep(0.5)

      ok, short, inline = 0, [], []
      for tid, sid in traces:
          ss = []
          for _ in range(25):
              ss = spans(tid)
              if ss and len(ss) > 1:
                  break
              time.sleep(1)
          server = [s for s in ss if "flask" in s["scope"] and
                    base64.b64decode(s.get("parentSpanId", "")) == bytes.fromhex(sid)]
          if not server:
              if not ss:
                  no(f"Tempo has nothing for trace {tid}, which the check started on POST /orders. The request",
                     "span comes from opentelemetry-instrument and the launcher block at the top of fulfil.py;",
                     "keep both. The end of /obs/logs/fulfil.log:", *log_tail())
              no(f"trace {tid} has no Flask request span under the check's own span.",
                 "Keep fulfil running under opentelemetry-instrument.")
          root = server[0]["spanId"]
          children = {}
          for s in ss:
              children.setdefault(s.get("parentSpanId"), []).append(s)
          below, todo = [], [root]
          while todo:
              for c in children.get(todo.pop(), []):
                  below.append(c)
                  todo.append(c["spanId"])
          server_end = int(server[0]["endTimeUnixNano"])
          long_ = [s for s in below if dur(s) >= JOB]
          if below and not long_:
              short = below
          elif long_ and not any(int(s["endTimeUnixNano"]) > server_end for s in long_):
              inline = long_
          elif below:
              ok += 1

      if ok == N:
          print(f"PASS — each of the check's {N} orders is one trace: the Flask request span from")
          print("opentelemetry-instrument, and under it a span covering the worker's job.")
          sys.exit(0)
      if inline:
          names = ", ".join(sorted({f"{s['name']!r} ({dur(s) * 1000:.0f}ms)" for s in inline}))
          no(f"the job's span, {names}, ends before the request span does: the job ran inside the",
             "request handler, so POST /orders now waits for it. The request should only queue the job",
             "and answer 202; the worker thread does the work and starts the span.")
      if short:
          names = ", ".join(sorted({f"{s['name']!r} ({dur(s) * 1000:.0f}ms)" for s in short}))
          no(f"the request span has a child, {names}, and none lasts as long as the job, which takes",
             "300ms or more. A span started in the request handler ends when the handler returns; the",
             "job runs later, on the worker thread. The worker has to start its span.")
      # The request spans are a few milliseconds long, so a span as long as the job, in a trace
      # the check did not start, is the worker's.
      orphans = tempo("/api/search", q="{" + SVC + " && duration >= 250ms}",
                      start=since, end=int(time.time()) + 1, limit=20).get("traces", [])
      orphans = [t for t in orphans if t["traceID"].lstrip("0") not in {tid.lstrip("0") for tid, _ in traces}]
      if orphans:
          no(f"the worker's spans reach Tempo, as traces of their own ({orphans[0].get('rootTraceName')!r},",
             f"trace {orphans[0]['traceID']}), with no parent. The worker thread has no current span: the",
             "request's context stays in the handler's thread unless the job carries it to the worker.")
      no(f"{N - ok} of the check's {N} orders have a request span and nothing under it. Nothing traces",
         "the worker: opentelemetry-instrument knows Flask and urllib, and the loop that takes jobs off",
         "the queue is fulfil's own code. Start a span there, in the request's trace.")
      PY
---
