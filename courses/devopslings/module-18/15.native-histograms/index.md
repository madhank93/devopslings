---
kind: lesson
title: "somewhere between 250 and 500"
description: |
  The search SLO is 300 ms at the 99th percentile, and the histogram's
  buckets jump from 250 ms to 500 ms, so the p99 query interpolates a number
  that is wrong by 40%. Another bucket only moves the problem. Switch to
  native histograms, whose buckets follow the data.
name: native-histograms
slug: native-histograms
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
      """search — the search service. Its queries are simulated in-process,
      50 a second, and their latency is recorded in a histogram sent over OTLP
      straight to prometheus-2 every 5 seconds.
      """
      import random
      import time

      from opentelemetry import metrics
      from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
      from opentelemetry.sdk.metrics import MeterProvider
      from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
      from opentelemetry.sdk.metrics.view import ExplicitBucketHistogramAggregation, View
      from opentelemetry.sdk.resources import Resource

      exporter = OTLPMetricExporter(endpoint="http://prometheus-2:9090/api/v1/otlp/v1/metrics")
      reader = PeriodicExportingMetricReader(exporter, export_interval_millis=5000)
      latency_view = View(
          instrument_name="search.request.duration",
          aggregation=ExplicitBucketHistogramAggregation([0.05, 0.1, 0.25, 0.5, 1, 2.5]),
      )
      metrics.set_meter_provider(MeterProvider(
          resource=Resource.create({"service.name": "search"}),
          metric_readers=[reader], views=[latency_view]))
      duration = metrics.get_meter("search").create_histogram(
          "search.request.duration", unit="s", description="Time to answer one search query.")


      def one_query():
          """Most queries hit the cache; one in twenty goes to the index."""
          if random.random() < 0.95:
              return random.uniform(0.04, 0.20)
          return random.uniform(0.30, 0.34)


      tick = time.monotonic()
      while True:
          duration.record(one_query())
          tick += 0.02
          time.sleep(max(0, tick - time.monotonic()))
      PY
      cat > /obs/prometheus-2/run.sh <<'SH'
      #!/usr/bin/env bash
      # prometheus-2: receives the search service's metrics over OTLP.
      # Saving this file restarts it.
      exec prometheus \
        --config.file=/obs/prometheus-2/prometheus.yml \
        --storage.tsdb.path=/tmp/prometheus-2 \
        --storage.tsdb.retention.time=6h \
        --web.enable-lifecycle \
        --web.enable-otlp-receiver
      SH
      chmod -R a+rX /obs/apps /obs/prometheus-2
      app_up prometheus-2; app_up lab
      for _ in $(seq 1 60); do
        [ "$(PROM=$PROM2 prom_count 'search_request_duration_seconds_bucket')" -gt 0 ] && break
        sleep 1
      done
      echo "scenario ready: search (/obs/apps/lab.py) records its latency in a histogram that"
      echo "prometheus-2 receives over OTLP. The SLO: 99% of queries under 300 ms."
      echo "  PROM=http://prometheus-2:9090 promq 'histogram_quantile(0.99, sum by (le) (rate(search_request_duration_seconds_bucket[1m])))'"

  verify_done:
    timeout_seconds: 300
    run: |
      . /usr/local/lib/obs.sh
      app_up prometheus-2; app_up lab
      p2() { PROM=$PROM2 "$@"; }
      for _ in $(seq 1 60); do curl -sf --max-time 2 "$PROM2/-/ready" >/dev/null && break; sleep 1; done

      # The true p99 of the simulated load: 95% of queries are under 200 ms
      # and the rest uniform over 300-340 ms, so p99 is 80% of the way
      # through that range.
      truth=0.332
      within() { python3 -c 'import sys; sys.exit(0 if abs(float(sys.argv[1]) / float(sys.argv[2]) - 1) <= 0.05 else 1)' "$1" "$truth"; }
      q='histogram_quantile(0.99, sum(rate(search_request_duration_seconds[1m])))'
      ok=0; p99=; native=
      for _ in $(seq 1 30); do
        native=$(curl -s --max-time 10 "$PROM2/api/v1/query" --data-urlencode 'query=search_request_duration_seconds' |
          jq -r '[.data.result[]? | select(.histogram)] | length' 2>/dev/null || echo 0)
        p99=$(p2 prom_val "$q")
        if [ "${native:-0}" -gt 0 ] && [ -n "$p99" ] && [ "$p99" != NaN ] && within "$p99"; then
          ok=$((ok + 1))
          [ "$ok" -ge 3 ] && break
        else
          ok=0
        fi
        sleep 5
      done
      if [ "$ok" -ge 3 ]; then
        echo "PASS — the native histogram's p99 is $(printf '%.0f' "$(python3 -c "print($p99*1000)")") ms; the load's true p99 is 332 ms."
        exit 0
      fi

      flags=$(curl -s --max-time 10 "$PROM2/api/v1/status/flags" | jq -r '."enable-feature" // ""' 2>/dev/null || true)
      classic=$(p2 prom_val 'histogram_quantile(0.99, sum by (le) (rate(search_request_duration_seconds_bucket[1m])))')
      if [ "${native:-0}" = 0 ]; then
        echo "not yet: prometheus-2 has no native histogram named search_request_duration_seconds."
        if [ -n "$classic" ]; then
          echo "The histogram still arrives as classic buckets (_bucket series, one per le), and their"
          echo "p99 is $classic s against a true 0.332 s. More buckets move the error to the next"
          echo "boundary; the SDK has to send an exponential histogram."
        elif ! grep -q 'native-histograms' <<<"$flags"; then
          echo "Nothing arrives at all. prometheus-2 runs with --enable-feature=${flags:-(none)}:"
          echo "without native-histograms it refuses the exponential histograms it is sent. See"
          echo "/obs/logs/lab.log for the exporter's side of that."
        else
          echo "Nothing arrives at all; see /obs/logs/lab.log and /obs/logs/prometheus-2.log."
        fi
        exit 1
      fi
      echo "not yet: the native histogram's p99 is ${p99:-nothing} s, more than 5% from the load's true"
      echo "0.332 s. An exponential histogram's resolution is set by its scale (or max size): one"
      echo "that is too coarse has buckets as wide as the classic ones."
      exit 1
---
