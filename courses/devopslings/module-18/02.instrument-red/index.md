---
kind: lesson
title: "orders has no metrics, so nobody knows it fails one order in twenty"
description: |
  orders takes customer orders. Prometheus scrapes it and gets connection
  refused, because orders has never exposed a metric. Give it the three
  numbers every request-serving service owes its operators: how many requests,
  how many failed, and how long they took, in units and buckets that tell the
  truth.
name: instrument-red
slug: instrument-red
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
      echo "scenario ready: orders serves GET /order on :8080 and exposes no metrics."
      echo "Prometheus already scrapes orders:9101 (job=\"orders\") and is refused."
      echo "Edit /obs/apps/orders.py; saving it restarts orders. Its output is in /obs/logs/orders.log."

  verify_done:
    timeout_seconds: 200
    run: |
      . /usr/local/lib/obs.sh
      obs_require_loaded || exit 1

      # A save restarts orders; let the restart and one scrape after it land
      # before judging, or the previous version is graded.
      edited=$(newest_mtime /obs/apps/orders.py /obs/run/orders.started)
      settle=$(( edited + 8 - $(date +%s) ))
      [ "$settle" -gt 0 ] && sleep "$settle"

      if ! prom_wait 'up{job="orders"} == 1' 20; then
        echo "not yet: Prometheus cannot scrape orders:9101."
        log=$(tail -n 30 /obs/logs/orders.log 2>/dev/null || true)
        # supervise restarts a dead app within a second or two, so a recent
        # start plus an exit line means a crash loop (a SyntaxError has no Traceback line).
        started=$(cat /obs/run/orders.started 2>/dev/null || echo 0)
        if [ $(( $(date +%s) - started )) -lt 10 ] && grep -q 'exited with status' <<<"$log"; then
          echo "orders is crashing on start. The end of /obs/logs/orders.log:"
          grep -v '^\[supervise\]' <<<"$log" | tail -n 8 | sed 's/^/  /'
        else
          echo "orders is running, and nothing answers on port 9101. prometheus_client's"
          echo "start_http_server(9101) serves the metrics endpoint."
        fi
        exit 1
      fi

      # Types as orders declares them right now, from its own endpoint.
      types=$(curl -s --max-time 5 http://orders:9101/metrics | awk '$1 == "#" && $2 == "TYPE" { print $3, $4 }' || true)
      meta() { awk -v m="$1" '$1 == m { print $2; exit }' <<<"$types"; }
      t_req=$(meta orders_requests_total)
      [ -n "$t_req" ] || t_req=$(meta orders_requests)
      t_dur=$(meta orders_request_duration_seconds)
      if [ "$t_req" != counter ]; then
        have=$(awk '$1 ~ /^orders_/ { print $1 }' <<<"$types" | paste -sd, - || true)
        if [ -z "$t_req" ]; then
          echo "not yet: no orders_requests_total. orders exposes: ${have:-no orders_* metrics}."
        else
          echo "not yet: orders_requests_total is a $t_req. A count of requests only ever goes up:"
          echo "make it a Counter, so rate() and increase() can work with it."
        fi
        exit 1
      fi
      if [ "$t_dur" != histogram ]; then
        if [ -z "$t_dur" ]; then
          echo "not yet: no orders_request_duration_seconds."
        elif [ "$t_dur" = summary ]; then
          echo "not yet: orders_request_duration_seconds is a summary. A summary's quantiles are"
          echo "computed inside one process and cannot be added up across instances or"
          echo "re-cut over a different window. Use a Histogram."
        else
          echo "not yet: orders_request_duration_seconds is a $t_dur. A single number per scrape"
          echo "cannot describe a distribution of request times. Use a Histogram."
        fi
        exit 1
      fi

      series=$(prom_count 'orders_requests_total{job="orders"}')
      if [ "$series" -gt 10 ]; then
        labels=$(prom_query 'orders_requests_total{job="orders"}' | jq -r '[.data.result[].metric | keys[]] | unique | map(select(. != "__name__" and . != "job" and . != "instance")) | join(", ")' 2>/dev/null || true)
        echo "not yet: orders_requests_total has $series series (labels: $labels). Every distinct label"
        echo "value is a new series kept in memory forever; label by status code, not by"
        echo "anything that is different on every request."
        exit 1
      fi
      if [ "$(prom_count 'orders_requests_total{job="orders",code="200"}')" = 0 ]; then
        labels=$(prom_query 'orders_requests_total{job="orders"}' | jq -c '[.data.result[].metric | del(.__name__, .job, .instance)]' 2>/dev/null || true)
        echo "not yet: orders_requests_total has no series with code=\"200\" (it has: $labels)."
        echo "Label each request with its HTTP status code, as a string, in a label named code."
        exit 1
      fi

      # Compare with what customers saw, over a minute that starts after orders
      # last restarted.
      started=$(cat /obs/run/orders.started 2>/dev/null || echo 0)
      wait=$(( started + 70 - $(date +%s) ))
      if [ "$wait" -gt 0 ]; then
        echo "waiting ${wait}s for a full minute of data since orders last started..."
        sleep "$wait"
      fi

      num() { awk -v v="${1:-0}" 'BEGIN { printf "%.3f", v + 0 }'; }
      truth=$(num "$(prom_val 'sum(increase(loadgen_requests_total{target="orders",code!="0"}[60s]))')")
      truth_err=$(num "$(prom_val 'sum(increase(loadgen_requests_total{target="orders",code="500"}[60s]))')")
      truth_avg=$(num "$(prom_val 'sum(increase(loadgen_request_duration_seconds_sum{target="orders"}[60s])) / sum(increase(loadgen_request_duration_seconds_count{target="orders"}[60s]))')")
      got=$(num "$(prom_val 'sum(increase(orders_requests_total{job="orders"}[60s]))')")
      got_err=$(num "$(prom_val 'sum(increase(orders_requests_total{job="orders",code="500"}[60s]))')")
      got_n=$(num "$(prom_val 'sum(increase(orders_request_duration_seconds_count{job="orders"}[60s]))')")
      got_avg=$(num "$(prom_val 'sum(increase(orders_request_duration_seconds_sum{job="orders"}[60s])) / sum(increase(orders_request_duration_seconds_count{job="orders"}[60s]))')")
      echo "last minute — customers saw: $truth requests, $truth_err errors, ${truth_avg}s average"
      echo "              orders reports: $got requests, $got_err errors, ${got_avg}s average ($got_n timed)"
      echo

      off() { awk -v a="$1" -v b="$2" -v t="$3" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d > t * b) }'; }
      if off "$got" "$truth" 0.2; then
        echo "not yet: orders counted $got requests in the last minute; customers sent $truth."
        echo "Count every request exactly once, whatever its outcome."
        exit 1
      fi
      if awk -v e="$got_err" -v t="$truth_err" 'BEGIN { d = e - t; if (d < 0) d = -d; exit !(d > 4 && d > 0.35 * t) }'; then
        if awk -v e="$got_err" 'BEGIN { exit !(e < 1) }'; then
          echo "not yet: customers got $truth_err errors from orders in the last minute and"
          echo "orders_requests_total{code=\"500\"} counted none. A failed request has to be counted too,"
          echo "with the code it was answered with."
        else
          echo "not yet: orders counted $got_err errors (code=\"500\") in the last minute; customers got"
          echo "$truth_err. Count each failure once, with the status code actually sent."
        fi
        exit 1
      fi
      if off "$got_n" "$got" 0.015; then
        echo "not yet: the histogram timed $got_n requests in the last minute, and orders counted"
        echo "$got. Time every request, including the ones that fail: slow failures are the"
        echo "ones you most need to see."
        exit 1
      fi
      if awk -v g="$got_avg" -v t="$truth_avg" 'BEGIN { exit !(g > 20 * t) }'; then
        echo "not yet: orders reports an average of ${got_avg}s per request; customers waited ${truth_avg}s."
        echo "That is about a thousand times too long, which is milliseconds recorded in a metric"
        echo "whose name says seconds. Prometheus base units are seconds."
        exit 1
      fi
      if off "$got_avg" "$truth_avg" 0.3; then
        echo "not yet: orders reports an average of ${got_avg}s per request; customers waited ${truth_avg}s."
        echo "The timer has to start before the work and stop after it."
        exit 1
      fi

      # Buckets: a quantile is interpolated inside one bucket, so the
      # distribution has to spread across several, and almost nothing may land
      # above the last finite one.
      b=$(prom_query 'sum by (le) (increase(orders_request_duration_seconds_bucket{job="orders"}[60s]))' | jq -r '
        [.data.result[] | {le: (.metric.le | if . == "+Inf" then infinite else tonumber end), n: (.value[1] | tonumber)}]
        | sort_by(.le) as $b | ($b | map(select(.le == infinite)) | .[0].n // 0) as $total
        | ($b | map(select(.le != infinite))) as $fin
        | (if ($fin | length) == 0 then 0 else $fin[-1].n end) as $top
        | [($fin | length),
           ($fin | map(select(.n > 0.02 * $total and .n < 0.98 * $total)) | length),
           (if $total > 0 then (($total - $top) / $total) else 0 end),
           (if ($fin | length) > 0 then $fin[-1].le else 0 end),
           ($fin | map(.le | tostring) | join(","))] | @tsv' 2>/dev/null || true)
      read -r nfin spread over top les <<<"${b:-0 0 0 0 -}"
      if awk -v o="$over" 'BEGIN { exit !(o > 0.02) }'; then
        pct=$(awk -v o="$over" 'BEGIN { printf "%.0f%%", o * 100 }')
        echo "not yet: $pct of requests took longer than the largest bucket (le=$top). Everything above"
        echo "it is only known to be \"more than $top seconds\". Buckets: $les"
        exit 1
      fi
      if [ "$spread" -lt 3 ]; then
        echo "not yet: nearly every request falls into the same one or two buckets (le=$les), so"
        echo "histogram_quantile can only guess inside them. Orders take tens of milliseconds to a"
        echo "couple of seconds; the buckets have to cover that range in several steps."
        exit 1
      fi

      p50=$(prom_val 'histogram_quantile(0.5, sum by (le) (rate(orders_request_duration_seconds_bucket{job="orders"}[60s])))')
      p99=$(prom_val 'histogram_quantile(0.99, sum by (le) (rate(orders_request_duration_seconds_bucket{job="orders"}[60s])))')
      ratio=$(awk -v e="$got_err" -v g="$got" 'BEGIN { printf "%.1f%%", (g > 0 ? e / g * 100 : 0) }')
      echo "PASS — rate, errors and duration agree with what customers saw:"
      echo "  error ratio $ratio, median $(num "$p50")s, p99 $(num "$p99")s"
---
