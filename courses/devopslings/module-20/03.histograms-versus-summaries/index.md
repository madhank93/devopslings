---
kind: lesson
title: "The average of four p99s"
description: |
  Search runs as four replicas, each reporting its own p99, and the fleet
  dashboard averages them: 490ms, comfortably inside the 800ms objective.
  One replica holds the hot shard. Compute the fleet's real p99 from the
  histogram buckets, and say how far wrong the average is.
name: histograms-versus-summaries
slug: histograms-versus-summaries
createdAt: "2026-11-16"

sandbox:
  stack: obs-stack
  service: box

tasks:
  init_scenario:
    init: true
    service: host
    timeout_seconds: 300
    run: |
      set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-20/*.histograms-versus-summaries
      lesson=$1
      docker compose exec -T box obs-reset >/dev/null
      # gateway-exporter runs whatever /obs/apps/gateway_exporter.py is, and
      # obs-reset puts the stub back, so the next lesson starts without it.
      docker compose exec -T box sh -c 'cat > /obs/apps/gateway_exporter.py' < "$lesson/files/search.py"
      docker compose exec -T box bash -euo pipefail -c '
        . /usr/local/lib/obs.sh
        cat >> /obs/prometheus/prometheus.yml <<YML

        - job_name: search
          static_configs:
            - targets: ["gateway-exporter:9401"]
              labels: { replica: a }
            - targets: ["gateway-exporter:9402"]
              labels: { replica: b }
            - targets: ["gateway-exporter:9403"]
              labels: { replica: c }
            - targets: ["gateway-exporter:9404"]
              labels: { replica: d }
      YML
        rm -f /obs/answers/fleet-p99.txt
        chmod -R a+rwX /obs/answers
        obs_reload >/dev/null
        prom_wait "count(rate(search_latency_hist_seconds_count[1m]) > 0) == 4" 90'
      echo "scenario ready — four search replicas (job=\"search\", label replica=a..d), each exporting"
      echo "search_latency_seconds (a summary) and search_latency_hist_seconds (a histogram)."
      echo "Write your answers in /obs/answers/fleet-p99.txt."

  verify_done:
    timeout_seconds: 60
    run: |
      . /usr/local/lib/obs.sh
      ans=/obs/answers/fleet-p99.txt
      field() { grep -E "^$1=" "$ans" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d ' %\r' || true; }
      num() { [[ "$1" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; }
      avg=$(field avg_p99_ms); fleet=$(field fleet_p99_ms); err=$(field error_pct)
      query=$(grep -E '^query=' "$ans" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      if ! num "$avg" || ! num "$fleet" || ! num "$err" || [ -z "$query" ]; then
        echo "not yet: $ans needs avg_p99_ms=, fleet_p99_ms=, error_pct= (numbers) and"
        echo "query=<the PromQL for the fleet p99>, one per line."
        exit 1
      fi
      ref_avg=$(prom_val '1000 * avg(search_latency_seconds{quantile="0.99"})')
      ref_max=$(prom_val '1000 * max(search_latency_seconds{quantile="0.99"})')
      ref_fleet=$(prom_val '1000 * histogram_quantile(0.99, sum by (le) (rate(search_latency_hist_seconds_bucket[1m])))')
      if [ -z "$ref_avg" ] || [ -z "$ref_fleet" ]; then
        echo "not yet: Prometheus has no recent data from the search replicas. Rerun the lesson's init."
        exit 1
      fi
      near() { awk -v a="$1" -v b="$2" -v t="$3" 'BEGIN { exit !(a - b <= b * t && b - a <= b * t) }'; }
      if ! near "$avg" "$ref_avg" 0.1; then
        echo "not yet: avg_p99_ms=$avg, but the average of the four replicas' p99s is about"
        echo "$(printf '%.0f' "$ref_avg")ms: the number the dashboard shows. Each replica's summary has a"
        echo "quantile=\"0.99\" series."
        exit 1
      fi
      res=$(prom_query "$query")
      qerr=$(jq -r '.error // empty' <<<"$res" 2>/dev/null || true)
      n=$(jq -r 'if .data.resultType == "scalar" then 1 else (.data.result | length) end' <<<"$res" 2>/dev/null || echo 0)
      got=$(jq -r 'if .data.resultType == "scalar" then .data.result[1] else (.data.result[0].value[1] // empty) end | tonumber? | . * 1000 | round' <<<"$res" 2>/dev/null || true)
      if [ -n "$qerr" ]; then
        echo "not yet: Prometheus rejected query=: $qerr"
        exit 1
      fi
      if ! grep -q 'search_latency_hist_seconds_bucket' <<<"$query"; then
        echo "not yet: query= does not read the histogram's buckets. A summary's quantiles were"
        echo "computed inside each replica, and no arithmetic on four of them gives the fleet's;"
        echo "buckets are counts, and counts add up across replicas."
        exit 1
      fi
      if [ "$n" -gt 1 ]; then
        echo "not yet: query= returns $n series, one per replica. Add the replicas' buckets together"
        echo "first, keeping only le, then take the quantile of the sum."
        exit 1
      fi
      if [ "$n" = 0 ] || [ -z "$got" ] || ! near "$got" "$ref_fleet" 0.1; then
        echo "not yet: query= returns ${got:-nothing}ms, not the fleet p99. A quantile taken per replica and"
        echo "then combined (avg, max) is still a combination of percentiles. Sum the bucket rates"
        echo "across the replicas by le, then apply histogram_quantile to the sum."
        exit 1
      fi
      if [ -n "$ref_max" ] && near "$fleet" "$ref_max" 0.03 && ! near "$ref_max" "$ref_fleet" 0.05; then
        echo "not yet: fleet_p99_ms=$fleet is the slowest replica's p99. That replica serves half the"
        echo "traffic, not all of it, so the fleet's p99 is lower. Use the value your query returns."
        exit 1
      fi
      if ! near "$fleet" "$ref_fleet" 0.1; then
        if near "$fleet" "$ref_avg" 0.05; then
          echo "not yet: fleet_p99_ms=$fleet is the average of the replicas' p99s, the number this lesson is"
          echo "about. Use the value your query returns."
        else
          echo "not yet: fleet_p99_ms=$fleet, but your query returns ${got}ms."
        fi
        exit 1
      fi
      want=$(awk -v a="$avg" -v f="$fleet" 'BEGIN { printf "%.0f", (a - f) / f * 100 }')
      if ! awk -v e="$err" -v w="$want" 'BEGIN { e = e < 0 ? -e : e; w = w < 0 ? -w : w; exit !(e - w <= 5 && w - e <= 5) }'; then
        alt=$(awk -v a="$avg" -v f="$fleet" 'BEGIN { printf "%.0f", (a - f) / a * 100 }')
        if awk -v e="$err" -v w="$alt" 'BEGIN { e = e < 0 ? -e : e; w = w < 0 ? -w : w; exit !(e - w <= 5 && w - e <= 5) }'; then
          echo "not yet: error_pct=$err measures the gap against the average. Measure it against the"
          echo "true value: (average − fleet) / fleet × 100."
        else
          echo "not yet: error_pct=$err. How far is the average of p99s from the fleet p99, as a"
          echo "percentage of the fleet p99?"
        fi
        exit 1
      fi
      echo "PASS — the dashboard says ${avg}ms; the fleet p99 is ${fleet}ms, so the average is off by ${want}%."
---
