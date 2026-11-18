---
kind: lesson
title: "A thousand requests, three numbers"
description: |
  Last night's load test against search made 1,000 requests, and the report
  says p50, p95 and p99. Work those three out yourself from the raw
  durations, then get the same answers from Prometheus, and say how many
  requests the p99 leaves out.
name: read-a-percentile
slug: read-a-percentile
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
      set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-20/*.read-a-percentile
      lesson=$1
      docker compose exec -T box obs-reset >/dev/null
      # gateway-exporter runs whatever /obs/apps/gateway_exporter.py is, and
      # obs-reset puts the stub back, so the next lesson starts without it.
      docker compose exec -T box sh -c 'cat > /obs/apps/gateway_exporter.py' < "$lesson/files/durations.py"
      docker compose exec -T box sh -c 'python3 - dump > /obs/answers/durations.txt' < "$lesson/files/durations.py"
      docker compose exec -T box bash -euo pipefail -c '
        . /usr/local/lib/obs.sh
        cat >> /obs/prometheus/prometheus.yml <<YML

        - job_name: loadtest
          static_configs:
            - targets: ["gateway-exporter:9400"]
      YML
        rm -f /obs/answers/percentiles.txt
        chmod -R a+rwX /obs/answers
        obs_reload >/dev/null
        prom_wait "count(search_test_request_duration_ms) == 1000" 60'
      echo "scenario ready — last night's 1,000 durations, in milliseconds and in the order sent,"
      echo "are in /obs/answers/durations.txt. Prometheus has the same numbers as"
      echo "search_test_request_duration_ms, one series per request."
      echo "Write your answers in /obs/answers/percentiles.txt."

  verify_done:
    timeout_seconds: 60
    run: |
      . /usr/local/lib/obs.sh
      ans=/obs/answers/percentiles.txt
      field() { grep -E "^$1=" "$ans" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d ' \r' || true; }
      num() { [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]; }
      p50=$(field p50); p95=$(field p95); p99=$(field p99); worse=$(field worse_than_p99)
      query=$(grep -E '^query=' "$ans" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      for v in "$p50" "$p95" "$p99" "$worse"; do
        if ! num "$v"; then
          echo "not yet: $ans needs p50=, p95=, p99= (in ms), worse_than_p99=<a count>,"
          echo "and query=<the PromQL that returns the p99>, one per line."
          exit 1
        fi
      done
      # The 1,000 values as Prometheus holds them, ascending: the check grades
      # against the data, not against stored answers.
      sorted=$(prom_query 'search_test_request_duration_ms' | jq -r '.data.result[].value[1]' 2>/dev/null | sort -g || true)
      if [ "$(wc -l <<<"$sorted")" != 1000 ]; then
        echo "not yet: Prometheus does not have the 1,000 durations (job loadtest). Rerun the lesson's init."
        exit 1
      fi
      at() { sed -n "$1p" <<<"$sorted"; }
      raw() { sed -n "$1p" /obs/answers/durations.txt 2>/dev/null || true; }
      mean=$(awk '{ s += $1 } END { printf "%.1f", s / NR }' <<<"$sorted")
      # The usual methods (nearest rank, or interpolating towards the next
      # value) all land between the rank and the one after it.
      for spec in "p50 $p50 500 501 500" "p95 $p95 950 951 950" "p99 $p99 990 991 990"; do
        set -- $spec
        lo=$(at "$3"); hi=$(at "$4")
        if awk -v v="$2" -v lo="$lo" -v hi="$hi" 'BEGIN { exit !(v >= lo && v <= hi) }'; then continue; fi
        if [ "$2" = "$(raw "$5")" ]; then
          echo "not yet: $1=$2 is line $5 of durations.txt, which is in the order the requests were"
          echo "sent. A percentile is a rank: sort the durations from fastest to slowest first."
        elif awk -v v="$2" -v m="$mean" 'BEGIN { exit !(v - m < 1 && m - v < 1) }'; then
          echo "not yet: $1=$2 is the mean of the 1,000 durations. The mean is pulled up by the slow"
          echo "tail; a percentile is the duration at a rank in the sorted list."
        else
          echo "not yet: $1=$2 is not the ${1#p}th percentile. Sort the 1,000 durations from fastest to"
          echo "slowest: the ${1#p}th percentile is the one ${1#p}% of requests are at or below, which is the"
          echo "$5th in the sorted list."
        fi
        exit 1
      done
      over=$(awk -v p="$p99" '$1 > p { n++ } END { print n + 0 }' <<<"$sorted")
      if [ "$worse" != "$over" ]; then
        case "$worse" in
          1) echo "not yet: worse_than_p99=1. That is the percentage; the answer is a count of requests out of 1,000." ;;
          99|990|989) echo "not yet: worse_than_p99=$worse counts the requests at or under the p99. The question is how many were slower." ;;
          *) echo "not yet: worse_than_p99=$worse. Count the durations in the file that are greater than your p99." ;;
        esac
        exit 1
      fi
      if [ -z "$query" ]; then
        echo "not yet: query= is empty. Write the PromQL expression that returns the p99 of the 1,000 series."
        exit 1
      fi
      if ! grep -q 'search_test_request_duration_ms' <<<"$query"; then
        echo "not yet: query= does not read search_test_request_duration_ms, so it is not computing"
        echo "anything from the data."
        exit 1
      fi
      res=$(prom_query "$query")
      err=$(jq -r '.error // empty' <<<"$res" 2>/dev/null || true)
      n=$(jq -r 'if .data.resultType == "scalar" then 1 else (.data.result | length) end' <<<"$res" 2>/dev/null || echo 0)
      got=$(jq -r 'if .data.resultType == "scalar" then .data.result[1] else (.data.result[0].value[1] // empty) end | tonumber? | . * 100 | round / 100' <<<"$res" 2>/dev/null || true)
      if [ -n "$err" ]; then
        echo "not yet: Prometheus rejected query=: $err"
        exit 1
      fi
      if [ "$n" = 0 ]; then
        echo "not yet: query= returns no data. These are 1,000 plain series, one value each: no"
        echo "histogram buckets, so histogram_quantile has nothing to work with."
        exit 1
      fi
      if [ "$n" != 1 ]; then
        echo "not yet: query= returns $n series. A percentile across requests aggregates across the"
        echo "series; the *_over_time functions work along time inside each series instead."
        exit 1
      fi
      if ! awk -v v="$got" -v lo="$(at 990)" -v hi="$(at 991)" 'BEGIN { exit !(v >= lo && v <= hi) }'; then
        echo "not yet: query= returns $got, which is not the p99 of the 1,000 durations."
        exit 1
      fi
      echo "PASS — p50 $p50, p95 $p95, p99 $p99 ms; Prometheus says $got; $worse requests were slower than the p99."
---
