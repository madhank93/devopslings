---
kind: lesson
title: "billing says the workers did 2,000 jobs, the graph says minus 800"
description: |
  The "jobs processed in the last 5 minutes" panel subtracts one counter
  reading from another, and every time a worker restarts it shows a number
  that never happened. Rewrite the query so it survives a restart and agrees
  with the billing ledger.
name: rate-versus-increase
slug: rate-versus-increase
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
      echo 'sum(worker_jobs_processed_total) - sum(worker_jobs_processed_total offset 5m)' \
        > /obs/queries/jobs-last-5m.promql
      chmod a+r /obs/queries/jobs-last-5m.promql
      # A routine restart, the kind that happens on every deploy.
      . /usr/local/lib/obs.sh
      app_restart worker-a
      echo "scenario ready: the panel's query is /obs/queries/jobs-last-5m.promql:"
      echo "  $(cat /obs/queries/jobs-last-5m.promql)"
      echo "Run it with: promq \"\$(cat /obs/queries/jobs-last-5m.promql)\""
      echo "The billing ledger, one line per finished job: /obs/run/ledger-a.log, ledger-b.log"

  verify_done:
    timeout_seconds: 120
    run: |
      . /usr/local/lib/obs.sh
      f=/obs/queries/jobs-last-5m.promql
      q=$(grep -v '^[[:space:]]*#' "$f" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)
      if [ -z "$q" ]; then
        echo "not yet: $f is missing or empty. It should hold one PromQL expression."
        exit 1
      fi
      err=$(prom_error "$q")
      if [ -n "$err" ]; then
        echo "not yet: Prometheus rejects the query: $err"
        exit 1
      fi

      # A deploy restarts worker-a. The query has to tell the truth across it.
      app_restart worker-a
      echo "restarted worker-a; waiting for Prometheus to scrape it a few times..."
      sleep 25

      r=$(prom_query "$q")
      n=$(jq -r 'if .data.resultType == "scalar" then 1 else (.data.result | length) end' <<<"$r" 2>/dev/null || echo 0)
      got=$(jq -r 'if .data.resultType == "scalar" then .data.result[1] else (.data.result[0].value[1] // empty) end' <<<"$r" 2>/dev/null || true)
      now=$(date +%s)
      # The ledger counts from each worker's first scrape at the earliest: jobs
      # before Prometheus ever saw a worker are in no metric at all.
      first=$(prom_query 'worker_jobs_processed_total[5m]' | jq -r '.data.result[]
        | "\(.metric.instance | split(":")[0] | ltrimstr("worker-")) \(.values[0][0])"' 2>/dev/null || true)
      truth=0
      for w in a b; do
        f=$(awk -v w="$w" '$1 == w { print $2 }' <<<"$first")
        cut=$(awk -v f="${f:-0}" -v t="$(( now - 300 ))" 'BEGIN { print (f > t ? f : t) }')
        jobs=$(awk -v t="$cut" '$1 > t { n++ } END { print n + 0 }' "/obs/run/ledger-$w.log" 2>/dev/null || echo 0)
        truth=$(( truth + jobs ))
      done
      started=$(jq -s 'min' /obs/run/worker-a.started /obs/run/worker-b.started 2>/dev/null || echo 0)

      if [ "$n" = 0 ]; then
        echo "not yet: the query returns no data."
        if grep -q 'offset' <<<"$q"; then
          echo "offset 5m needs data from five minutes ago, and it reads one raw sample there."
        fi
        exit 1
      fi
      if [ "$n" -gt 1 ]; then
        echo "not yet: the query returns $n series. The panel shows one number: jobs processed by all"
        echo "workers together."
        exit 1
      fi
      printf -v shown '%.0f' "$got" 2>/dev/null || shown=$got
      echo "billing ledger: $truth jobs in the last 5 minutes; the query says $shown"
      close() { awk -v g="$1" -v t="$2" -v k="${3:-1}" 'BEGIN { g *= k; d = g - t; if (d < 0) d = -d; exit !(d <= 0.08 * t + 15) }'; }
      if close "$got" "$truth"; then
        echo "PASS — the query survives a worker restart and agrees with the ledger."
        exit 0
      fi

      if awk -v g="$got" 'BEGIN { exit !(g < 0) }'; then
        echo "not yet: a negative number of jobs. worker-a restarted, its counter started again from 0,"
        echo "and subtracting an old reading from a new one went below zero. Raw counter values only"
        echo "mean something relative to the process that produced them. rate() and increase()"
        echo "detect a counter going down and treat it as a restart."
      elif close "$got" "$truth" 300; then
        echo "not yet: that is per second. rate() gives the average per-second rate over the window;"
        echo "the panel asks for a count of jobs over 5 minutes, which is what increase() returns."
      elif awk -v g="$got" -v t="$truth" 'BEGIN { exit !(g > 1.3 * t) }'; then
        echo "not yet: the query counts more jobs than were done."
        if grep -Eq '(rate|increase)\s*\(\s*sum' <<<"$q"; then
          echo "It sums the workers first and takes increase() of the sum. When worker-a restarts, the"
          echo "sum drops by worker-a's whole count, increase() takes that drop for a reset of the sum,"
          echo "and counts everything worker-b had done as new. Take rate() or increase() of each"
          echo "series, then sum: sum(increase(...))."
        else
          echo "A drop in a counter is read as a restart; anything that lowers a series without a"
          echo "restart (summing processes first, max/min over time) is miscounted."
        fi
      else
        echo "not yet: the query does not agree with the ledger across worker-a's restart."
        if grep -Eq '\b(delta|deriv|idelta)\s*\(' <<<"$q"; then
          echo "delta() is for gauges: it subtracts the first sample from the last and knows nothing"
          echo "about resets, so a counter that restarted from 0 loses everything before the restart."
        fi
        if grep -q 'offset' <<<"$q" && ! grep -Eq '\b(rate|increase)\s*\(' <<<"$q"; then
          echo "offset 5m reads one raw sample from five minutes ago. When a worker restarted in"
          echo "between, that sample came from a process that is gone, and its counter has nothing to"
          echo "do with the new one's: the difference is not a count of anything."
        fi
        echo "Count jobs per worker with increase() over the last 5 minutes, then add the workers up."
      fi
      exit 1
---
