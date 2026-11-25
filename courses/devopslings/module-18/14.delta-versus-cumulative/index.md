---
kind: lesson
title: "the counter that saws"
description: |
  A service instrumented with the OpenTelemetry SDK sends its request count
  through the Collector to Prometheus, and the graph is a sawtooth: rate()
  says the service does almost nothing. Each data point is the count since
  the last one, not since the start. Make the series cumulative.
name: delta-versus-cumulative
slug: delta-versus-cumulative
createdAt: "2026-11-23"
timingSensitive: true

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
      """tickets — the ticket service. Its customers are simulated in-process:
      exactly 8 requests a second. Metrics go out over OTLP to the Collector
      every 5 seconds.
      """
      import time

      from opentelemetry import metrics
      from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
      from opentelemetry.sdk.metrics import Counter, MeterProvider
      from opentelemetry.sdk.metrics.export import AggregationTemporality, PeriodicExportingMetricReader
      from opentelemetry.sdk.resources import Resource

      exporter = OTLPMetricExporter(
          endpoint="http://collector:4318/v1/metrics",
          preferred_temporality={Counter: AggregationTemporality.DELTA},
      )
      reader = PeriodicExportingMetricReader(exporter, export_interval_millis=5000)
      metrics.set_meter_provider(MeterProvider(
          resource=Resource.create({"service.name": "tickets"}), metric_readers=[reader]))
      requests = metrics.get_meter("tickets").create_counter(
          "tickets.requests", description="Requests the ticket service answered.")

      tick = time.monotonic()
      while True:
          requests.add(1, {"route": "/book"})
          tick += 0.125
          time.sleep(max(0, tick - time.monotonic()))
      PY
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
        otlphttp/loki:
          endpoint: http://loki:3100/otlp
        otlphttp/tempo:
          endpoint: http://tempo:4318
        # prometheus-2's OTLP receiver: /api/v1/otlp/v1/metrics
        otlphttp/prometheus:
          endpoint: http://prometheus-2:9090/api/v1/otlp

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
          traces:
            receivers: [otlp]
            processors: [batch]
            exporters: [otlphttp/tempo]
          metrics:
            receivers: [otlp]
            processors: [batch]
            exporters: [otlphttp/prometheus]
      YML
      cat > /obs/prometheus-2/run.sh <<'SH'
      #!/usr/bin/env bash
      # prometheus-2: receives the tickets service's metrics over OTLP.
      # Saving this file restarts it.
      exec prometheus \
        --config.file=/obs/prometheus-2/prometheus.yml \
        --storage.tsdb.path=/tmp/prometheus-2 \
        --storage.tsdb.retention.time=6h \
        --web.enable-lifecycle \
        --web.enable-otlp-receiver \
        --enable-feature=otlp-native-delta-ingestion
      SH
      chmod -R a+rX /obs/apps /obs/otel /obs/prometheus-2
      app_up prometheus-2; app_up lab
      for _ in $(seq 1 60); do
        [ "$(PROM=$PROM2 prom_count 'tickets_requests_total')" -gt 0 ] && break
        sleep 1
      done
      echo "scenario ready: tickets (/obs/apps/lab.py) answers exactly 8 requests a second and sends"
      echo "its metrics through the Collector (/obs/otel/collector.yaml) to prometheus-2. Ask it:"
      echo "  PROM=http://prometheus-2:9090 promq 'rate(tickets_requests_total[1m])'"

  verify_done:
    timeout_seconds: 300
    run: |
      . /usr/local/lib/obs.sh
      app_up prometheus-2; app_up lab
      p2() { PROM=$PROM2 "$@"; }
      for _ in $(seq 1 60); do curl -sf --max-time 2 "$PROM2/-/ready" >/dev/null && break; sleep 1; done

      ok=0; rate=; resets=; seen=
      for _ in $(seq 1 30); do
        rate=$(p2 prom_val 'sum(rate(tickets_requests_total[30s]))')
        resets=$(p2 prom_val 'sum(resets(tickets_requests_total[30s]))')
        [ -n "$rate" ] && seen=1
        if [ -n "$rate" ] && [ "${resets%.*}" = 0 ] &&
           python3 -c 'import sys; sys.exit(0 if abs(float(sys.argv[1]) - 8) <= 1 else 1)' "$rate"; then
          ok=$((ok + 1))
          [ "$ok" -ge 3 ] && break
        else
          ok=0
        fi
        sleep 5
      done
      if [ "$ok" -ge 3 ]; then
        echo "PASS — rate(tickets_requests_total[30s]) is $(printf '%.2f' "$rate") a second, and tickets answers 8."
        exit 0
      fi

      if [ -z "$seen" ]; then
        echo "not yet: prometheus-2 has had no tickets_requests_total for two and a half minutes."
        if grep -qiE 'error|refused' <(tail -n 20 /obs/logs/collector.log 2>/dev/null); then
          echo "The Collector's log ends with errors; look at /obs/logs/collector.log."
        fi
        if ! grep -q 'otlp-native-delta-ingestion\|otlp-deltatocumulative' /obs/prometheus-2/run.sh; then
          echo "prometheus-2 now runs without a delta feature flag, and Prometheus drops delta"
          echo "samples it was not told how to handle. Removing the flag hides the deltas; it"
          echo "does not turn them into a counter."
        fi
        exit 1
      fi
      last=$(curl -s --max-time 10 "$PROM2/api/v1/query" --data-urlencode 'query=tickets_requests_total[30s]' |
        jq -r '[.data.result[0].values[]?[1] | tonumber | floor] | map(tostring) | join(" ")' 2>/dev/null || true)
      echo "not yet: tickets answers 8 requests a second; rate(tickets_requests_total[30s]) says"
      echo "${rate:-nothing}, with ${resets:-?} counter resets in 30 seconds."
      echo "The last 30 seconds of samples: ${last:-none}."
      echo "A counter only goes up. A series that hovers around one number is a count per export"
      echo "interval (delta temporality), and rate(), increase() and resets() all read each dip as"
      echo "a process restart. A longer window or another function reads the same wrong data; the"
      echo "samples themselves have to be running totals."
      exit 1
---
