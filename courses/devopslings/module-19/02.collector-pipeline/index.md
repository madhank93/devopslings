---
kind: lesson
title: "The Collector is running, and none of storefront's logs reach Loki"
description: |
  The platform team rolled out an OpenTelemetry Collector for logs. It
  starts, it reports no errors, and Loki has nothing from storefront. Every
  part the pipeline needs is defined in its config. Wire them together, in an
  order that does what each one is for.
name: collector-pipeline
slug: collector-pipeline
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
      cat > /obs/otel/collector.yaml <<'YML'
      # The logs pipeline for every service. Apps send OTLP over HTTP to
      # collector:4318. Saving this file restarts the Collector; its output is
      # in /obs/logs/collector.log.
      receivers:
        otlp:
          protocols:
            grpc:
              endpoint: 0.0.0.0:4317

      processors:
        # Refuse data before the Collector runs out of memory.
        memory_limiter:
          check_interval: 1s
          limit_mib: 150
          spike_limit_mib: 30
        batch:
          timeout: 1s
        # Stamp every record with the environment it came from.
        resource/env:
          attributes:
            - key: deployment.environment
              value: prod
              action: upsert
        # Older services report url.path; dashboards and the filter below use http.route.
        attributes/normalize:
          actions:
            - key: http.route
              from_attribute: url.path
              action: upsert
            - key: url.path
              action: delete
        # Load balancer health checks are noise.
        filter/healthchecks:
          error_mode: ignore
          logs:
            log_record:
              - 'attributes["http.route"] == "/healthz"'

      exporters:
        debug:
          verbosity: basic
        otlphttp/loki:
          endpoint: http://loki:3100/otlp

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
            processors: [batch, filter/healthchecks, attributes/normalize, memory_limiter]
            exporters: [debug]
      YML
      cat > /obs/otel/sample-log.json <<'JSON'
      {"resourceLogs": [{
        "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "storefront"}}]},
        "scopeLogs": [{"logRecords": [
          {"severityText": "INFO", "body": {"stringValue": "GET /cart 200"},
           "attributes": [{"key": "url.path", "value": {"stringValue": "/cart"}}]},
          {"severityText": "INFO", "body": {"stringValue": "GET /healthz 200"},
           "attributes": [{"key": "url.path", "value": {"stringValue": "/healthz"}}]}
        ]}]
      }]}
      JSON
      . /usr/local/lib/obs.sh
      collector_settle >/dev/null || true
      echo "scenario ready: the Collector runs /obs/otel/collector.yaml. Send it what storefront sends:"
      echo "  curl -H 'Content-Type: application/json' http://collector:4318/v1/logs -d @/obs/otel/sample-log.json"
      echo "then look in Loki: logcli query '{service_name=\"storefront\"}' --since=10m"

  verify_done:
    timeout_seconds: 90
    run: |
      . /usr/local/lib/obs.sh
      collector_settle || exit 1
      python3 - <<'PY'
      import json, sys, time, urllib.parse, urllib.request, uuid
      import yaml

      def no(*lines):
          print("not yet: " + lines[0])
          for l in lines[1:]:
              print(l)
          sys.exit(1)

      cfg = yaml.safe_load(open("/obs/otel/collector.yaml")) or {}
      pipe = ((cfg.get("service") or {}).get("pipelines") or {}).get("logs") or {}
      procs = [p for p in pipe.get("processors") or []]
      exps = pipe.get("exporters") or []

      run = uuid.uuid4().hex[:10]
      def rec(path):
          return {"timeUnixNano": str(time.time_ns()), "severityText": "INFO",
                  "body": {"stringValue": f"check {run} GET {path} 200"},
                  "attributes": [{"key": "url.path", "value": {"stringValue": path}}]}
      body = {"resourceLogs": [{"resource": {"attributes": [
          {"key": "service.name", "value": {"stringValue": "storefront"}}]},
          "scopeLogs": [{"logRecords": [rec("/cart"), rec("/healthz")]}]}]}
      req = urllib.request.Request("http://collector:4318/v1/logs", data=json.dumps(body).encode(),
                                   headers={"Content-Type": "application/json"})
      try:
          urllib.request.urlopen(req, timeout=10).read()
      except urllib.error.HTTPError as e:
          no(f"the Collector answered {e.code} to an OTLP/HTTP log request:", "  " + e.read().decode()[:200])
      except OSError as e:
          no("nothing accepts OTLP over HTTP on collector:4318, where storefront sends its logs",
             f"({getattr(e, 'reason', e)}). Which protocols does the otlp receiver listen on?")

      def find(text):
          now = time.time_ns()
          q = urllib.parse.urlencode({"query": f'{{service_name="storefront"}} |= "{text}"',
                                      "start": now - 600 * 10**9, "end": now + 60 * 10**9})
          try:
              with urllib.request.urlopen(f"http://loki:3100/loki/api/v1/query_range?{q}", timeout=10) as r:
                  return [s["stream"] for s in json.load(r)["data"]["result"]]
          except OSError:
              return []

      for _ in range(20):
          cart = find(f"check {run} GET /cart")
          if cart:
              break
          time.sleep(0.5)
      if not cart:
          if "otlphttp/loki" not in exps:
              no(f"the logs pipeline exports to {', '.join(exps) or 'nothing'}. The Collector received the record",
                 "and handed it to an exporter that prints it to the Collector's own log. Defining an",
                 "exporter does nothing until a pipeline lists it.")
          no("a storefront record sent to collector:4318 did not reach Loki within 10 seconds.",
             "Look for export errors in /obs/logs/collector.log.")
      labels = cart[0]

      if labels.get("deployment_environment") != "prod":
          no("storefront's record reached Loki without deployment.environment=\"prod\" (it has:",
             f"  {', '.join(sorted(labels))}).",
             "The processor that sets it is defined; is it in the pipeline?")
      if "url_path" in labels or labels.get("http_route") != "/cart":
          no("storefront's record reached Loki with url.path and no http.route=\"/cart\". Dashboards",
             "query http.route; the processor that renames it is defined. Is it in the pipeline?")
      time.sleep(1)
      if find(f"check {run} GET /healthz"):
          names = [p.split("/")[0] for p in procs]
          if "filter" not in names:
              no("a /healthz record reached Loki. The filter that drops health checks is defined and",
                 "not in the pipeline.")
          no("a /healthz record reached Loki. The pipeline is",
             f"  processors: [{', '.join(procs)}]",
             "Processors run in the order listed. The filter matches http.route == \"/healthz\";",
             "what is that attribute called when the record reaches the filter?")
      if not procs or procs[0] != "memory_limiter":
          no("records arrive intact, and the pipeline is",
             f"  processors: [{', '.join(procs)}]",
             "memory_limiter refuses data when memory is short. Anywhere but first, the processors",
             "before it have already taken the memory it was meant to protect, and a batch",
             "processor ahead of it has already accepted data it can no longer refuse.")
      filters = [i for i, p in enumerate(procs) if p.split("/")[0] == "filter"]
      if "batch" in procs and filters and procs.index("batch") < max(filters):
          no("records arrive intact, and the pipeline is",
             f"  processors: [{', '.join(procs)}]",
             "batch groups records for the exporter. Ahead of a filter, it holds and groups records",
             "that are then thrown away. It goes after anything that drops data.")
      print(f"PASS — storefront's record is in Loki with {{{', '.join(f'{k}={v!r}' for k, v in sorted(labels.items()))}}},")
      print("and the health check was dropped.")
      PY
