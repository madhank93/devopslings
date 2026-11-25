---
kind: lesson
title: "A traceback arrives in Loki as thirty lines, and only two of them say which report"
description: |
  reports renders PDFs on request and logs to a file, which the Collector
  tails into Loki. When a render fails, Python writes one record with the
  whole traceback in it, and Loki gets thirty separate lines. The one that
  names the report and the one that names the error are found; the
  frames in between belong to nobody. Make each traceback one record.
name: multiline-stack-traces
slug: multiline-stack-traces
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
      cat > /obs/apps/lab.py <<'PY'
      """reports — renders reports on request, on :8080, and logs to /obs/logs/reports.log.

      GET /report?id=<id> renders one. A report whose data has a section with no
      rows fails, and the failure is logged with its traceback. Saving this file
      restarts it.
      """
      import logging
      import random
      import threading
      import time
      import urllib.parse
      import urllib.request
      import uuid
      from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

      handler = logging.FileHandler("/obs/logs/reports.log")
      handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s [%(threadName)s] %(message)s"))
      log = logging.getLogger("reports")
      log.addHandler(handler)
      log.setLevel(logging.INFO)

      SECTIONS = ["cover", "summary", "regions", "region", "accounts", "account", "orders",
                  "order", "lines", "line", "taxes", "totals"]


      def render(report_id, data, depth=0):
          time.sleep(0.005)
          if depth == len(SECTIONS) - 1:
              if not data:
                  raise ValueError(f"report {report_id}: section {SECTIONS[depth]!r} has no rows")
              return 1
          return render(report_id, data, depth + 1) + 1


      class Handler(BaseHTTPRequestHandler):
          def log_message(self, *a):
              pass

          def do_GET(self):
              q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
              rid = q.get("id", [uuid.uuid4().hex[:8]])[0]
              threading.current_thread().name = f"req-{rid[-4:]}"
              log.info("report %s started", rid)
              try:
                  pages = render(rid, [] if q.get("fail") else [1])
              except Exception:
                  log.exception("report %s failed", rid)
                  self.send_response(500)
                  self.end_headers()
                  return
              log.info("report %s done, %d pages", rid, pages)
              self.send_response(200)
              self.end_headers()


      def traffic():
          """Customers asking for reports; one in twelve has an empty section."""
          while True:
              fail = "&fail=1" if random.random() < 1 / 12 else ""
              try:
                  urllib.request.urlopen(f"http://127.0.0.1:8080/report?id=r-{uuid.uuid4().hex[:8]}{fail}",
                                         timeout=5).read()
              except Exception:
                  pass
              time.sleep(random.uniform(0.05, 0.3))


      for _ in range(3):
          threading.Thread(target=traffic, daemon=True).start()
      ThreadingHTTPServer.daemon_threads = True
      ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
      PY
      : > /obs/logs/reports.log
      chmod a+rw /obs/logs/reports.log
      cat > /obs/otel/collector.yaml <<'YML'
      # reports' log file to Loki. Saving this file restarts the Collector; its
      # output is in /obs/logs/collector.log.
      receivers:
        filelog/reports:
          include: [/obs/logs/reports.log]
          start_at: end
          resource:
            service.name: reports

      processors:
        batch:
          timeout: 1s

      exporters:
        otlphttp/loki:
          endpoint: http://loki:3100/otlp

      service:
        pipelines:
          logs:
            receivers: [filelog/reports]
            processors: [batch]
            exporters: [otlphttp/loki]
      YML
      collector_settle >/dev/null || true
      app_up lab
      echo "scenario ready: reports (/obs/apps/lab.py, in the lab container) logs to"
      echo "/obs/logs/reports.log, and the Collector tails that file into Loki. Its failures:"
      echo "  logcli query '{service_name=\"reports\"} |= \"failed\"' --since=5m --limit=5"

  verify_done:
    timeout_seconds: 90
    run: |
      . /usr/local/lib/obs.sh
      collector_settle || exit 1
      python3 - <<'PY'
      import json, re, sys, threading, time, urllib.parse, urllib.request, uuid

      LOKI = "http://loki:3100"
      LOG = "/obs/logs/reports.log"
      STAMP = re.compile(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d{3} ")

      def no(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print(l)
          sys.exit(1)

      def show(text, n=4):
          rows = text.split("\n")
          out = ["    | " + r[:110] for r in rows[:n]]
          if len(rows) > n:
              out.append(f"    | … {len(rows) - n} more lines")
          return out

      def query(q, start):
          args = urllib.parse.urlencode({"query": q, "start": start, "end": time.time_ns(),
                                         "limit": 1000, "direction": "forward"})
          try:
              with urllib.request.urlopen(f"{LOKI}/loki/api/v1/query_range?{args}", timeout=15) as r:
                  body = json.load(r)
          except OSError as e:
              no(f"Loki did not answer a query ({e}).")
          return [line for s in body["data"]["result"] for _, line in sorted(s["values"])]

      # Three reports fail at the same moment, among the usual traffic.
      start = time.time_ns()
      ids = [f"r-{uuid.uuid4().hex[:8]}" for _ in range(3)]
      gate = threading.Barrier(3)
      def fail(rid):
          gate.wait()
          try:
              urllib.request.urlopen(f"http://lab:8080/report?id={rid}&fail=1", timeout=10).read()
          except urllib.error.HTTPError:
              pass
          except OSError as e:
              print(f"  reports did not answer for {rid}: {e}")
      ts = [threading.Thread(target=fail, args=(r,)) for r in ids]
      for t in ts:
          t.start()
      for t in ts:
          t.join()

      # What reports wrote for each: its "started" line and its error record,
      # header through the exception line.
      def written(rid):
          lines = open(LOG).read().split("\n")
          started = next((l for l in lines if l.endswith(f"report {rid} started")), None)
          at = next((i for i, l in enumerate(lines) if STAMP.match(l) and l.endswith(f"report {rid} failed")), None)
          if started is None or at is None:
              return None
          end = at + 1
          while end < len(lines) and lines[end] and not STAMP.match(lines[end]):
              end += 1
          return started, "\n".join(lines[at:end])

      truth = {r: written(r) for r in ids}
      lost = [r for r, t in truth.items() if t is None]
      if lost and all(r in open(LOG).read() for r in lost):
          no(f"reports wrote {lost[0]} to {LOG}, but not as `<timestamp> … report {lost[0]} failed`.",
             "The lesson's fix is in how the Collector reads the file; put lab.py back as init wrote it.")
      if lost:
          no(f"reports did not log the failure of {', '.join(lost)} to {LOG}. Is it running?",
             "The end of /obs/logs/lab.log:", *[l.rstrip()[:160] for l in open("/obs/logs/lab.log").readlines()[-4:]])

      # The multiline rule is only exercised by a real traceback, frames through
      # the ValueError (Python folds the repeated render() frames into one line).
      for rid, (_, block) in truth.items():
          rows = block.split("\n")
          if len(rows) < 8 or rows[1] != "Traceback (most recent call last):" \
                  or not rows[-1].startswith(f"ValueError: report {rid}:"):
              no(f"reports no longer writes the traceback for {rid}; its failure record in {LOG} is",
                 *show(block),
                 "The lesson's fix is in how the Collector reads the file; put lab.py back as init wrote it.")

      # Each record in Loki that mentions the report, once the Collector has
      # flushed: a multiline record is held until the next one starts.
      deadline = time.time() + 20
      while True:
          found = {r: query(f'{{service_name="reports"}} |= `{r}`', start) for r in ids}
          if all(len(v) >= 2 for v in found.values()) or time.time() > deadline:
              break
          time.sleep(2)

      for rid in ids:
          started, block = truth[rid]
          recs = [l.rstrip("\n") for l in found[rid]]
          nlines = block.count("\n") + 1
          if not recs:
              no(f"nothing in Loki mentions {rid}, whose failure reports logged 20 seconds ago.",
                 "Is the Collector still tailing /obs/logs/reports.log into Loki? The end of",
                 "/obs/logs/collector.log:", *[l.rstrip()[:160] for l in open("/obs/logs/collector.log").readlines()[-3:]])
          if any(r == block for r in recs) and started in recs and len(recs) == 2:
              continue
          if started not in recs:
              holder = next((r for r in recs if started in r), None)
              if holder is not None:
                  no(f"the line `{started[24:]}` is not a record of its own. It arrived inside",
                     "a record with other lines in it:", *show(holder),
                     "A record starts at each line that begins with a timestamp, and only there.")
          header = block.split("\n")[0]
          if header in recs:
              no(f"{rid} failed with a {nlines}-line traceback, and Loki has the line that says so,",
                 f"`{header[24:]}`, as a record on its own. The {nlines - 1} lines of traceback after it",
                 "are in other records, and the frames in them never mention the report.",
                 "Join them into the record they belong to as the Collector reads the file.")
          whole = [r for r in recs if block in r and r != block]
          if whole:
              extra = [l for l in whole[0].split("\n") if l not in block.split("\n")]
              no(f"the record for {rid}'s failure holds its whole traceback and more: lines that",
                 "belong to other requests, e.g.", *["    | " + l[:110] for l in extra[:2]],
                 "A record has to end where the next timestamped line starts.")
          part = [r for r in recs if r != block and r in block]
          if part:
              no(f"{rid}'s failure is split across {len(recs) - (started in recs)} records in Loki; one of them is",
                 *show(part[0]),
                 f"reports wrote it as one {nlines}-line record, header to exception.")
          no(f"Loki's records for {rid} do not match what reports wrote. In the file:", *show(block),
             "In Loki:", *[x for r in recs for x in show(r, 2)])

      print(f"PASS — three reports failed at once, and Loki has each failure as one record holding its")
      print(f"whole traceback, header to exception, with every other line still a record of its own.")
      PY
---
