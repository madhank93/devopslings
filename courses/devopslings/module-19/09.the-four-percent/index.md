---
kind: lesson
title: "Finance counts 4% fewer invoices in the logs than billing issued"
description: |
  Every invoice billing issues is logged, and finance reconciles the logs
  against the ledger. The logs come up a few percent short every day. No
  error anywhere says so. The first guess is that billing sometimes forgets
  to log. Find where the lines go, stop it, and make sure the next drop
  pages someone instead of waiting for finance.
name: the-four-percent
slug: the-four-percent
createdAt: "2026-11-14"

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
      cat > /obs/otel/collector.yaml <<'YML'
      # billing's logs to Loki. Saving this file restarts the Collector; its
      # output is in /obs/logs/collector.log, its own metrics on collector:8888.
      receivers:
        otlp:
          protocols:
            http:
              endpoint: 0.0.0.0:4318

      processors:
        batch:
          send_batch_size: 20
          send_batch_max_size: 20
          timeout: 500ms

      exporters:
        otlphttp/loki:
          endpoint: http://loki:3100/otlp
          # Sized for steady traffic: one sender, a short queue.
          sending_queue:
            num_consumers: 1
            queue_size: 5

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
          logs:
            receivers: [otlp]
            processors: [batch]
            exporters: [otlphttp/loki]
      YML
      cat >> /obs/prometheus/prometheus.yml <<'YML'

        - job_name: collector
          static_configs:
            - targets: ["collector:8888"]

        - job_name: billing
          static_configs:
            - targets: ["billing:9101"]
      YML
      obs_reload >/dev/null
      collector_settle >/dev/null || true
      app_up billing
      echo "scenario ready: billing logs every invoice to the Collector, which ships to Loki."
      echo "billing counts what it sent in billing_log_records_total; Loki has the rest:"
      echo "  logcli query 'sum(count_over_time({service_name=\"billing\"}[5m]))'"
      echo "Prometheus now scrapes billing and the Collector (collector:8888)."

  verify_done:
    timeout_seconds: 150
    run: |
      . /usr/local/lib/obs.sh
      obs_require_loaded || exit 1
      collector_settle || exit 1
      python3 - <<'PY'
      import json, re, subprocess, sys, time, urllib.parse, urllib.request, uuid
      from concurrent.futures import ThreadPoolExecutor

      def no(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print(l)
          sys.exit(1)

      def failed():
          """The Collector's own count of log records its exporters dropped, by how."""
          try:
              text = urllib.request.urlopen("http://collector:8888/metrics", timeout=5).read().decode()
          except OSError:
              return None
          total = {"enqueue": 0.0, "send": 0.0}
          for l in text.splitlines():
              m = re.match(r"otelcol_exporter_(enqueue|send)_failed_log_records(?:_total)?\{.*\} (\S+)", l)
              if m:
                  total[m.group(1)] += float(m.group(2))
          return total

      # Two shapes of burst: a month-end settlement run of 1000 lines in one
      # request, and 50 invoices of 20 lines each sent at once.
      def send(tag, n):
          now = str(time.time_ns())
          body = {"resourceLogs": [{"resource": {"attributes": [
              {"key": "service.name", "value": {"stringValue": "billing"}}]},
              "scopeLogs": [{"logRecords": [{"timeUnixNano": now, "severityText": "INFO",
                                             "body": {"stringValue": f"{tag} line {i}"}} for i in range(n)]}]}]}
          try:
              urllib.request.urlopen(urllib.request.Request(
                  "http://collector:4318/v1/logs", data=json.dumps(body).encode(),
                  headers={"Content-Type": "application/json"}), timeout=60).read()
          except urllib.error.HTTPError as e:
              return f"the Collector answered {e.code}: {e.read().decode()[:160]}"
          except OSError as e:
              return f"nothing accepts OTLP/HTTP on collector:4318 ({getattr(e, 'reason', e)})"

      def count(tag):
          q = urllib.parse.urlencode({"query": f'sum(count_over_time({{service_name="billing"}} |= "{tag}" [10m]))',
                                      "time": time.time_ns()})
          try:
              with urllib.request.urlopen(f"http://loki:3100/loki/api/v1/query?{q}", timeout=10) as r:
                  res = json.load(r)["data"]["result"]
              return int(float(res[0]["value"][1])) if res else 0
          except OSError:
              return 0

      def arrived(tag, want):
          got, stable = 0, 0
          for _ in range(40):
              time.sleep(1)
              n = count(tag)
              stable = stable + 1 if n == got else 0
              got = n
              if got >= want or (got and stable >= 5):
                  break
          return got

      def judge(what, want, got, before, after):
          if got >= want:
              return
          how = []
          if before and after:
              how = ["The Collector's own metrics moved while it happened:",
                     f"  otelcol_exporter_enqueue_failed_log_records +{after['enqueue'] - before['enqueue']:.0f}",
                     f"  otelcol_exporter_send_failed_log_records    +{after['send'] - before['send']:.0f}"]
          no(f"{what} reached Loki as {got} of {want} lines.",
             "The rest were lost without an error to the sender.", *how)

      run = uuid.uuid4().hex[:10]
      before = failed()
      err = send(f"settlement {run}", 1000)
      if err:
          no(f"a settlement run of 1000 lines: {err}")
      got = arrived(f"settlement {run} ", 1000)
      after = failed()
      if got < 1000:
          judge("a settlement run of 1000 lines in one request", 1000, got, before, after)

      before = failed()
      with ThreadPoolExecutor(25) as pool:
          errs = [e for e in pool.map(lambda i: send(f"invoices {run}-{i}", 20), range(50)) if e]
      if errs:
          full = ["billing does not read the answer, so to billing this is a silent drop too. The",
                  "queue that refused them is still too small for a burst."] if "queue is full" in errs[0] else []
          no(f"50 invoices sent at once: {len(errs)} of them refused: {errs[0]}", *full)
      got = arrived(f"invoices {run}-", 1000)
      after = failed()
      judge("50 invoices of 20 lines, sent at the same moment,", 1000, got, before, after)

      # The alert, run against histories where the answer is known.
      rules = subprocess.run(["sh", "-c", "ls /obs/prometheus/rules/*.yml 2>/dev/null"], capture_output=True, text=True).stdout.split()
      have = [f for f in rules if re.search(r"alert:\s*LogRecordsDropped\b", open(f).read())]
      if not have:
          no("no rule file in /obs/prometheus/rules defines an alert named LogRecordsDropped.")
      labels = 'exporter="otlphttp/loki",job="collector",instance="collector:8888"'
      def fires(enqueue, send, at):
          test = {"rule_files": have, "evaluation_interval": "1m", "tests": [{
              "interval": "1m",
              "input_series": [s for s in (
                  {"series": f"otelcol_exporter_enqueue_failed_log_records_total{{{labels}}}", "values": enqueue},
                  {"series": f"otelcol_exporter_send_failed_log_records_total{{{labels}}}", "values": send}) if s["values"]],
              "promql_expr_test": [{"expr": 'clamp_max(count(ALERTS{alertname="LogRecordsDropped",alertstate="firing"}), 1)',
                                    "eval_time": at, "exp_samples": [{"labels": "{}", "value": 1}]}]}]}
          open("/tmp/four-percent-test.yml", "w").write(json.dumps(test))
          p = subprocess.run(["promtool", "test", "rules", "/tmp/four-percent-test.yml"], capture_output=True, text=True)
          if p.returncode != 0 and "FAILED" not in p.stdout + p.stderr:
              no("promtool could not run the alert's rule file:", *["  " + l for l in (p.stdout + p.stderr).strip().splitlines()[-4:]])
          return p.returncode == 0

      # The queue overflows: enqueue_failed appears, then keeps climbing.
      if not fires("_x5 20+20x15", "0x25", "18m"):
          no("LogRecordsDropped did not fire when the Collector dropped 20 records a minute for",
             "12 minutes, counted in otelcol_exporter_enqueue_failed_log_records_total.")
      # The backend refuses and retries run out: only send_failed moves.
      if not fires("", "0x5 0+20x15", "18m"):
          if fires("0x25", "0x5 0+20x15", "18m"):
              no("LogRecordsDropped fires when send_failed rises only if enqueue_failed has a series too.",
                 "The Collector does not export enqueue_failed until the first enqueue failure, and",
                 "a + b is empty when either side has no series.")
          no("LogRecordsDropped did not fire when the exporter gave up on 20 records a minute,",
             "counted in otelcol_exporter_send_failed_log_records_total. A full queue is one way an",
             "exporter drops data; running out of retries is the other.")
      # Last month's incident: both counters non-zero and flat.
      if fires("120x30", "40x30", "30m"):
          no("LogRecordsDropped fires when nothing is being dropped: both counters have been flat",
             "for 30 minutes after an old incident. A counter's value is everything since the",
             "Collector started. The question is whether it is going up now.")

      try:
          ans = open("/obs/answers/the-four-percent.txt").read()
      except OSError:
          ans = ""
      m = re.search(r"^\s*where\s*:(.*)$", ans, re.M | re.I)
      if not m or not m.group(1).strip():
          no("/obs/answers/the-four-percent.txt needs a line `where: …` naming the component that",
             "dropped the lines.")
      where = m.group(1).lower()
      if not re.search(r"\b(queue|sending_queue|otlphttp/loki|otlphttp|exporter)\b", where):
          if re.search(r"\bbatch", where):
              no("the answer blames the batch processor. It handed on every record it received:",
                 "otelcol_processor_batch_batch_send_size_sum keeps pace with what billing sent.",
                 "Which component's counter says it failed to take records?")
          no(f"the answer says the lines were dropped at {m.group(1).strip()!r}. Which Collector metric",
             "counts them, and which component does it belong to?")
      print("PASS — a 1000-line settlement run and 50 simultaneous invoices reached Loki whole, and")
      print("LogRecordsDropped fires on either way the exporter drops data, only while it happens.")
      PY
