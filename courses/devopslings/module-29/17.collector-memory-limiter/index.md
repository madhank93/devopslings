---
kind: lesson
title: "The Collector dies every night at the import"
description: |
  Every night the importer replays a day of orders and sends a burst of
  spans through the Collector. Tempo throttles the burst, the Collector
  holds what it cannot send yet, and the kernel kills it for running out of
  memory, losing everything it held. Make it survive the burst.
name: collector-memory-limiter
slug: collector-memory-limiter
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
      mkdir -p /obs/tools
      cat > /obs/tools/importer <<'PY'
      #!/usr/bin/env python3
      """importer — replays a day of orders as spans, as fast as the Collector takes them.

        importer [REQUESTS]   default 600 requests of 200 spans, 16 at a time

      Prints what the Collector answered: 200 accepted, anything else refused.
      """
      import os, sys, time, urllib.error, urllib.request
      from concurrent.futures import ThreadPoolExecutor
      from opentelemetry.proto.collector.trace.v1.trace_service_pb2 import ExportTraceServiceRequest

      ROW = "x" * 2048

      def payload():
          req = ExportTraceServiceRequest()
          rs = req.resource_spans.add()
          a = rs.resource.attributes.add()
          a.key, a.value.string_value = "service.name", "importer"
          ss = rs.scope_spans.add()
          now = time.time_ns()
          for _ in range(200):
              s = ss.spans.add()
              s.trace_id, s.span_id = os.urandom(16), os.urandom(8)
              s.name = "import order"
              s.start_time_unix_nano, s.end_time_unix_nano = now, now + 1_000_000
              at = s.attributes.add()
              at.key, at.value.string_value = "order.row", ROW
          return req.SerializeToString()

      def send(_):
          r = urllib.request.Request("http://collector:4318/v1/traces", data=payload(),
                                     headers={"Content-Type": "application/x-protobuf"})
          try:
              urllib.request.urlopen(r, timeout=30).read()
              return "200"
          except urllib.error.HTTPError as e:
              return str(e.code)
          except OSError:
              return "no answer"

      n = int(sys.argv[1]) if len(sys.argv) > 1 else 600
      t = time.time()
      with ThreadPoolExecutor(16) as ex:
          got = list(ex.map(send, range(n)))
      print(f"{n} requests in {time.time() - t:.1f}s: " +
            ", ".join(f"{got.count(c)} {c}" for c in sorted(set(got))))
      PY
      chmod +x /obs/tools/importer
      python3 - <<'PY'
      import yaml
      p = "/obs/otel/collector.yaml"
      c = yaml.safe_load(open(p))
      # Tempo refuses a request over 4MB; a thousand of the importer's spans fit.
      c["processors"]["batch"] = {"timeout": "1s", "send_batch_size": 1000, "send_batch_max_size": 1000}
      yaml.safe_dump(c, open(p, "w"), sort_keys=False)
      PY
      collector_settle >/dev/null || true
      echo "scenario ready: the Collector (/obs/otel/collector.yaml, log /obs/logs/collector.log)"
      echo "runs in a container with 256MiB of memory. Run the nightly burst yourself: importer"
  verify_done:
    timeout_seconds: 300
    run: |
      . /usr/local/lib/obs.sh
      collector_settle || exit 1
      python3 - <<'PY'
      import os, re, subprocess, sys, time, urllib.request, yaml

      CFG = "/obs/otel/collector.yaml"

      def no(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print(l)
          sys.exit(1)

      def started():
          try:
              return int(open("/obs/run/collector.started").read())
          except (OSError, ValueError):
              return 0

      def log_lines():
          try:
              return open("/obs/logs/collector.log", errors="replace").readlines()
          except OSError:
              return []

      def selfmetric(name):
          try:
              text = urllib.request.urlopen("http://collector:8888/metrics", timeout=5).read().decode()
          except OSError as e:
              no(f"the check could not read the Collector's own metrics at collector:8888 ({e}).",
                 "It needs them to see memory_limiter's refusals; leave service.telemetry as it was.")
          return sum(float(m) for m in re.findall(rf"^{name}(?:{{[^}}]*}})? (\S+)", text, re.M))

      c = yaml.safe_load(open(CFG)) or {}
      procs = c.get("processors") or {}
      pipes = (c.get("service") or {}).get("pipelines") or {}
      traces = {n: p for n, p in pipes.items() if n.split("/")[0] == "traces"}
      if not traces:
          no("the Collector has no traces pipeline left, so the importer's spans go nowhere.")
      for n, p in traces.items():
          if "otlphttp/tempo" not in (p.get("exporters") or []):
              no(f"pipeline {n} no longer exports to Tempo. The spans still have to arrive.")
          ps = p.get("processors") or []
          if not any(x.split("/")[0] == "memory_limiter" for x in ps):
              no(f"pipeline {n} has processors [{', '.join(ps)}] and no memory_limiter. Nothing",
                 "in it decides to stop accepting data, so it accepts until the kernel kills it.")
          if ps[0].split("/")[0] != "memory_limiter":
              no(f"pipeline {n} runs [{', '.join(ps)}]. memory_limiter refuses data to the sender,",
                 "and only the first processor can: by the time data reaches a later one, the",
                 "receiver has already answered 200 and the processors ahead of it hold the memory.")
          if ps[-1].split("/")[0] != "batch":
              no(f"pipeline {n} runs [{', '.join(ps)}]; batch belongs last, right before the exporter.")

      # The check's own burst, from a freshly started Collector.
      r = subprocess.run(["bash", "-c", ". /usr/local/lib/obs.sh; app_restart collector; collector_settle"],
                         capture_output=True, text=True)
      if r.returncode:
          out = r.stdout.strip()
          if out.startswith("not yet"):
              print(out)
              sys.exit(1)
          no("the Collector did not settle after the check restarted it.", *(out or r.stderr).splitlines()[-3:])
      time.sleep(3)
      before, mark = started(), len(log_lines())
      try:
          run = subprocess.run(["/obs/tools/importer", "600"], capture_output=True, text=True, timeout=60)
      except subprocess.TimeoutExpired:
          no("the check's burst of 600 requests did not finish in 60s; it normally takes a few seconds.",
             "The Collector is holding requests open instead of answering them.")
      if run.returncode:
          no("the importer itself failed during the check's burst:", *("  " + l for l in run.stderr.splitlines()[-3:]))
      print("the check's burst: " + run.stdout.strip())
      time.sleep(15)
      deaths = [l for l in log_lines()[mark:] if l.startswith("[supervise] collector exited")]
      if deaths or started() != before:
          limit = next((v for k, v in procs.items() if k.split("/")[0] == "memory_limiter"), None) or {}
          def num(v):
              try:
                  return float(v or 0)
              except (TypeError, ValueError):
                  return 0.0
          if num(limit.get("limit_mib")) >= 256 or num(limit.get("limit_percentage")) >= 100:
              no("the Collector died during the burst. memory_limiter's limit is at or above the",
                 "256MiB the container is allowed, so the kernel kills the process before the",
                 "limiter ever thinks memory is short.")
          no("the Collector died during the burst " + (deaths[0].strip() if deaths else "(it restarted)") + ".",
             "memory_limiter is in place, but memory still outran it. Its limit sits too close to",
             "the container's 256MiB, or it checks too rarely for how fast a burst arrives:",
             "spike_limit has to cover what arrives between two checks.")
      codes = {}
      for n, code in re.findall(r"(\d+) (\d{3}|no answer)", run.stdout):
          codes[code] = codes.get(code, 0) + int(n)
      other = {c: n for c, n in codes.items() if c not in ("200", "503", "no answer")}
      if other:
          no("the Collector rejected " + ", ".join(f"{n} requests with {c}" for c, n in other.items()) + ".",
             "Those spans were never let in. memory_limiter answers 503 while memory is short;",
             "a 4xx comes from something else, such as a receiver limit, turning the burst away.")
      if codes.get("no answer"):
          no(f"{codes['no answer']} of the burst's requests got no answer at all: the Collector dropped",
             "the connection instead of replying, so the importer cannot tell whether to retry.")
      refused = selfmetric("otelcol_processor_refused_spans(?:_total)?")
      if refused == 0:
          if codes.get("503"):
              no(f"the Collector answered 503 to {codes['503']} requests, but memory_limiter's refused-spans",
                 "counter stayed at 0, so those 503s did not come from memory_limiter.")
          dropped = selfmetric("otelcol_exporter_enqueue_failed_spans(?:_total)?")
          if dropped:
              no(f"the Collector stayed up and answered 200 to every request, then threw away",
                 f"{dropped:g} spans because the exporter's queue was full. The importer believes",
                 "they were delivered. Refusing them, so the sender can retry, is the point.")
          no("the Collector stayed up and accepted the whole burst without refusing anything.",
             "That only means the burst was smaller than its limit; the check needs to see",
             "memory_limiter push back.")
      if not codes.get("200"):
          no(f"not one of the burst's requests got a 200 ({codes.get('503', 0)} got 503 from memory_limiter).",
             "A limiter that refuses everything protects the Collector by delivering nothing.")

      # Once the burst is over, new spans have to be accepted and reach Tempo.
      tid = "17" + os.urandom(15).hex()
      body = ('{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"importer"}}]},'
              '"scopeSpans":[{"spans":[{"traceId":"%s","spanId":"%s","name":"after the burst","kind":1,'
              '"startTimeUnixNano":"%d","endTimeUnixNano":"%d"}]}]}]}'
              % (tid, os.urandom(8).hex(), time.time_ns(), time.time_ns() + 1000000)).encode()
      deadline = time.time() + 90
      while True:
          try:
              urllib.request.urlopen(urllib.request.Request("http://collector:4318/v1/traces", data=body,
                                     headers={"Content-Type": "application/json"}), timeout=10).read()
              break
          except OSError:
              if time.time() > deadline:
                  no("90s after the burst the Collector still refuses new spans. memory_limiter lets",
                     "data in again once memory falls below its soft limit (limit minus spike);",
                     "a soft limit below what the Collector needs at rest refuses for ever.")
              time.sleep(2)
      deadline = time.time() + 120
      while True:
          try:
              urllib.request.urlopen(f"http://tempo:3200/api/traces/{tid}", timeout=10).read()
              break
          except OSError:
              if time.time() > deadline:
                  no("the Collector accepted a span after the burst and Tempo never got it.")
              time.sleep(3)
      print(f"PASS — memory_limiter refused {refused:g} of the burst's spans with backpressure,")
      print("stayed up through it, and passed new spans on to Tempo afterwards.")
      PY
---
