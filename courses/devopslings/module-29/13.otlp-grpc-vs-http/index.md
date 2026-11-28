---
kind: lesson
title: "billing exports spans and the Collector gets none"
description: |
  billing is a new service with tracing turned on. It makes spans, its
  exporter points at the Collector's OTLP port, and nothing ever shows up in
  Tempo. Get billing's spans through the Collector, with the exporter's
  protocol and the port it talks to agreeing.
name: otlp-grpc-vs-http
slug: otlp-grpc-vs-http
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
      cat > /obs/apps/billing.py <<'PY'
      """billing — issues an invoice every few hundred milliseconds, one span
      per invoice, exported over OTLP to the Collector.
      """
      import os
      import random
      import time

      # The exporter's settings. Set here, they act exactly as the same
      # variables would from the process environment.
      os.environ["OTEL_SERVICE_NAME"] = "billing"
      os.environ["OTEL_EXPORTER_OTLP_PROTOCOL"] = "http/protobuf"
      os.environ["OTEL_EXPORTER_OTLP_ENDPOINT"] = "http://collector:4317"

      from opentelemetry import trace
      from opentelemetry.sdk.trace import TracerProvider
      from opentelemetry.sdk.trace.export import BatchSpanProcessor

      if os.environ["OTEL_EXPORTER_OTLP_PROTOCOL"] == "grpc":
          from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
      else:
          from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter

      provider = TracerProvider()
      provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(), schedule_delay_millis=500))
      trace.set_tracer_provider(provider)
      tracer = trace.get_tracer("billing")

      n = int(time.time()) % 100000 * 100
      while True:
          n += 1
          with tracer.start_as_current_span("issue invoice") as span:
              span.set_attribute("invoice.id", f"inv-{n}")
              time.sleep(random.uniform(0.005, 0.02))
          time.sleep(random.uniform(0.2, 0.4))
      PY
      cat > /obs/answers/otlp-ports.txt <<'TXT'
      # Which protocol each standard OTLP port speaks. '#' starts a comment.
      4317: ?   # grpc or http
      4318: ?   # grpc or http
      TXT
      for a in billing; do app_restart "$a"; app_up "$a"; done
      echo "scenario ready: billing makes a span per invoice and exports it to the Collector, and"
      echo "Tempo has none:"
      echo "  curl -s 'http://tempo:3200/api/search?q={resource.service.name=\"billing\"}&limit=5' | jq '.traces | length'"
      echo "billing: /obs/apps/billing.py and /obs/logs/billing.log. The Collector: /obs/otel/collector.yaml."
      echo "Your answer: /obs/answers/otlp-ports.txt"

  verify_done:
    timeout_seconds: 120
    run: |
      . /usr/local/lib/obs.sh
      collector_settle || exit 1
      python3 - <<'PY'
      import json, re, sys, time, urllib.parse, urllib.request
      import yaml

      ANSWER = "/obs/answers/otlp-ports.txt"

      def no(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print(l)
          sys.exit(1)

      def tail(app, pattern=""):
          try:
              lines = [l for l in open(f"/obs/logs/{app}.log") if re.search(pattern, l)]
              return ["  " + l.rstrip()[:240] for l in lines[-3:]]
          except OSError:
              return []

      answers = {}
      try:
          for line in open(ANSWER):
              m = re.match(r"\s*(\d+)\s*:\s*([^#]*)", line)
              if m:
                  answers[m.group(1)] = m.group(2).strip().lower()
      except OSError:
          no(f"{ANSWER} is missing. Reset the lesson to get the template back.")
      for port in ("4317", "4318"):
          if answers.get(port, "?") in ("", "?"):
              no(f"{port} in {ANSWER} is not filled in.")
      a17, a18 = answers["4317"], answers["4318"]
      if a17 != "grpc" or not a18.startswith("http"):
          no(f"{ANSWER} says 4317 speaks '{a17}' and 4318 speaks '{a18}'. Look at the receivers in",
             "/obs/otel/collector.yaml: which protocol listens on which port?")

      try:
          cfg = yaml.safe_load(open("/obs/otel/collector.yaml"))
          protos = cfg["receivers"]["otlp"]["protocols"]
          g = str((protos.get("grpc") or {}).get("endpoint", ""))
          h = str((protos.get("http") or {}).get("endpoint", ""))
      except (OSError, yaml.YAMLError, KeyError, TypeError, AttributeError) as e:
          no(f"/obs/otel/collector.yaml has no otlp receiver the check can read ({e}).")
      if not g.endswith(":4317") or not h.endswith(":4318"):
          no(f"the Collector's otlp receiver listens for gRPC on '{g}' and HTTP on '{h}'. 4317 is gRPC and",
             "4318 is HTTP everywhere OTLP is spoken; a Collector that swaps them breaks every other",
             "sender that uses the defaults. Change the exporter, not the receiver.")

      def accepted():
          out = {}
          try:
              with urllib.request.urlopen("http://collector:8888/metrics", timeout=10) as r:
                  for line in r.read().decode().splitlines():
                      m = re.match(r'otelcol_receiver_accepted_spans(?:_total)?\{([^}]*)\}\s+(\S+)', line)
                      if m and 'receiver="otlp"' in m.group(1):
                          t = re.search(r'transport="([^"]+)"', m.group(1))
                          out[t.group(1) if t else "?"] = out.get(t.group(1) if t else "?", 0) + float(m.group(2))
          except OSError:
              pass
          return out

      # supervise restarts an edited app within half a second; until then
      # .started still holds the previous start.
      time.sleep(1)
      try:
          since = int(open("/obs/run/billing.started").read())
      except (OSError, ValueError):
          since = int(time.time())
      time.sleep(max(0, since + 3 - time.time()))
      before = accepted()
      start = int(time.time())
      time.sleep(8)
      after = accepted()
      grew = {t: after.get(t, 0) - before.get(t, 0) for t in after if after.get(t, 0) > before.get(t, 0)}

      q = urllib.parse.urlencode({"q": '{resource.service.name="billing"}', "start": start - 1,
                                  "end": int(time.time()) + 1, "limit": 50})
      found = []
      for _ in range(10):
          try:
              with urllib.request.urlopen(f"http://tempo:3200/api/search?{q}", timeout=10) as r:
                  found = json.load(r).get("traces", [])
          except OSError as e:
              no(f"Tempo did not answer a search ({e}).")
          if found:
              break
          time.sleep(2)

      if not found:
          no("no billing span reached Tempo in the last 25s. billing's exporter errors, from",
             "/obs/logs/billing.log:", *tail("billing", r"(?i)export|error|fail|status|refused|unavailable"))
      if not grew:
          no("billing's spans reach Tempo and the Collector accepted none of them: they go around it.",
             "The Collector is where sampling, redaction and batching happen for every service; send",
             "to it.")
      t = ", ".join(sorted(grew))
      print(f"PASS — billing's spans arrive in Tempo through the Collector's otlp receiver ({t}),")
      print("and the protocol matches the port: gRPC on 4317, HTTP on 4318.")
      PY
---
