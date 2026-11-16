---
kind: lesson
title: "the latency panel times out on the week view"
description: |
  shop's "p99 by route" panel computes a quantile from raw histogram buckets
  every time anyone loads it. Over a week of data it times out. Precompute it
  with a recording rule, point the panel at the result, and make sure the
  rule says exactly what the raw query said.
name: recording-rules
slug: recording-rules
createdAt: "2026-10-15"

sandbox:
  stack: obs-stack
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 120
    run: |
      obs-reset >/dev/null
      echo 'histogram_quantile(0.99, sum by (le, route) (rate(shop_http_request_duration_seconds_bucket[5m])))' \
        > /obs/queries/latency-panel.promql
      chmod a+r /obs/queries/latency-panel.promql
      echo "scenario ready: the panel's query is /obs/queries/latency-panel.promql:"
      echo "  $(cat /obs/queries/latency-panel.promql)"
      echo "Recording rules go in /obs/prometheus/rules/*.yml; load them with obs-reload."

  verify_done:
    timeout_seconds: 300
    run: |
      . /usr/local/lib/obs.sh
      RAW='histogram_quantile(0.99, sum by (le, route) (rate(shop_http_request_duration_seconds_bucket[5m])))'
      BUDGET=5000
      obs_require_loaded || exit 1

      f=/obs/queries/latency-panel.promql
      q=$(grep -v '^[[:space:]]*#' "$f" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)
      if [ -z "$q" ]; then
        echo "not yet: $f is missing or empty. It holds the panel's query."
        exit 1
      fi
      err=$(prom_error "$q")
      if [ -n "$err" ]; then
        echo "not yet: Prometheus rejects the panel's query: $err"
        exit 1
      fi

      # What one load of the panel costs: a range query over its last 15
      # minutes, as Grafana sends it, counted in samples read.
      cost() {
        local end; end=$(date +%s)
        curl -s --max-time 30 "$PROM/api/v1/query_range" --data-urlencode "query=$1" \
          --data-urlencode "start=$(( end - 900 ))" --data-urlencode "end=$end" \
          --data-urlencode step=15 --data-urlencode stats=all \
          | jq -r '.data.stats.samples.totalQueryableSamples // empty' 2>/dev/null || true
      }
      # Right after a start there is too little history for the raw query to be
      # expensive; wait until it reads enough that the comparison means something.
      for _ in $(seq 1 30); do
        raw_cost=$(cost "$RAW")
        [ "${raw_cost:-0}" -ge 2000 ] && break
        sleep 5
      done
      got_cost=$(cost "$q")
      echo "one load of the panel over 15 minutes reads ${got_cost:-?} samples (the raw query: ${raw_cost:-?};"
      echo "over a week, about 700 times as many)"
      if [ "${got_cost:-$BUDGET}" -ge "$BUDGET" ] || [ $(( ${got_cost:-$BUDGET} * 8 )) -gt "${raw_cost:-0}" ]; then
        echo "not yet: the panel's query reads ${got_cost:-?} samples per load; the budget is under $BUDGET"
        echo "and under an eighth of the raw query's ${raw_cost:-?}."
        echo "Every load recomputes rate() over 5 minutes of raw buckets at every step of the graph."
        echo "A recording rule computes it once per evaluation and stores the answer; the panel"
        echo "should read the stored series."
        exit 1
      fi

      if ! prom_wait "$q" 20; then
        echo "not yet: the panel's query returns no data. If it reads a recorded series, check the"
        echo "rule is loaded and evaluating: http://localhost:19090/rules, or"
        echo "  curl -s prometheus:9090/api/v1/rules | jq '.data.groups[].rules[] | {name, health, lastError}'"
        exit 1
      fi

      # Per route, the panel against the raw query, now.
      byroute() {
        prom_query "$1" | jq -c '[.data.result[] | select(.value[1] != "NaN") | {(.metric.route // "-"): (.value[1] | tonumber)}] | add // {}' 2>/dev/null || echo '{}'
      }
      want=$(byroute "$RAW"); have=$(byroute "$q")
      routes_w=$(jq -r 'keys | join(", ")' <<<"$want"); routes_h=$(jq -r 'keys | join(", ")' <<<"$have")
      if [ "$routes_h" != "$routes_w" ]; then
        echo "not yet: the panel shows one line per route ($routes_w), and the query returns"
        echo "series for: ${routes_h:-nothing}."
        if [ "$routes_h" = "-" ]; then
          echo "The route label is gone. An aggregation keeps only the labels in its by (...): the"
          echo "rule has to keep route, and le until histogram_quantile has used it."
        fi
        exit 1
      fi
      bad=$(jq -rn --argjson w "$want" --argjson h "$have" '
        def ms: . * 1000 + 0.5 | floor;
        [$w | keys[] | . as $k | select(($w[$k] - ($h[$k] // 0)) | (if . < 0 then -. else . end) > 0.1 * $w[$k] + 0.002)
         | "\($k): raw \($w[$k] | ms)ms, panel \(($h[$k] // 0) | ms)ms"] | join("; ")' 2>/dev/null || echo "the values could not be compared")
      if [ -n "$bad" ]; then
        echo "not yet: the panel and the raw query disagree: $bad."
        echo "A recording rule has to compute exactly what the panel used to: the same quantile, the"
        echo "same rate window, the same labels. Otherwise the fast panel answers a different question."
        exit 1
      fi

      echo "PASS — the panel reads ${got_cost} samples per load instead of ${raw_cost}, and shows the same p99 per"
      echo "route as the raw query: $(jq -r 'to_entries | map("\(.key) \((.value // 0) * 1000 + 0.5 | floor)ms") | join(", ")' <<<"$have")"
---
