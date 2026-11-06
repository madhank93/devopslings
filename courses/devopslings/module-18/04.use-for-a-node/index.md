---
kind: lesson
title: "db is slow, and its CPU is idle"
description: |
  shop's cart pages time out. The db node's CPU sits at a few percent, memory
  is flat, and the team's dashboard says db is fine. Walk db's resources with
  the USE method — utilisation, saturation, errors — find the one that is
  saturated, and write the three queries that would have shown it.
name: use-for-a-node
slug: use-for-a-node
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
      # A migration holds a lock every query waits on, connection in hand.
      touch /obs/run/db.fault
      echo "scenario ready: shop's /cart and /orders pages are slow and failing; db's CPU is idle."
      echo "Write your three queries to /obs/queries/use-utilisation.promql, use-saturation.promql"
      echo "and use-errors.promql. Try each with: promq \"\$(cat /obs/queries/use-saturation.promql)\""

  verify_done:
    timeout_seconds: 300
    run: |
      . /usr/local/lib/obs.sh
      pids=()
      # Leave db as the scenario has it: slow, with the lock held.
      cleanup() { kill "${pids[@]}" 2>/dev/null || true; touch /obs/run/db.fault; }
      trap cleanup EXIT

      declare -A Q
      for k in utilisation saturation errors; do
        f=/obs/queries/use-$k.promql
        Q[$k]=$(grep -v '^[[:space:]]*#' "$f" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)
        if [ -z "${Q[$k]}" ]; then
          echo "not yet: $f is missing or empty. It should hold one PromQL expression: the $k"
          echo "of the resource you think is saturated."
          exit 1
        fi
        err=$(prom_error "${Q[$k]}")
        if [ -n "$err" ]; then
          echo "not yet: Prometheus rejects use-$k.promql: $err"
          exit 1
        fi
        # The check measures each state for about half a minute; a longer
        # window would still be averaging the previous one.
        long=$(grep -oE '\[[0-9]+(ms|s|m|h)' <<<"${Q[$k]}" | tr -d '[' | awk '
          { n = $0 + 0; u = $0; sub(/^[0-9]+/, "", u)
            s = (u == "ms") ? n / 1000 : (u == "s") ? n : (u == "m") ? n * 60 : n * 3600
            if (s > 30) { print $0; exit } }' || true)
        if [ -n "$long" ]; then
          echo "not yet: use-$k.promql uses a [$long] window. The check measures db healthy and"
          echo "saturated for about half a minute each, so windows have to be 30s or shorter here."
          exit 1
        fi
      done

      # Sum of every series the expression returns; "none" when it returns none.
      total() {
        prom_query "$1" | jq -r '
          if .status != "success" then "none"
          elif .data.resultType == "scalar" then .data.result[1]
          elif (.data.result | length) == 0 then "none"
          else ([.data.result[].value[1] | tonumber] | add) end' 2>/dev/null || echo none
      }
      # Mean over four evaluations, three seconds apart, for every query plus
      # the pool's own queue length as ground truth.
      measure() {
        local -A sum=() ; local i k v
        for i in 1 2 3 4; do
          for k in utilisation saturation errors; do
            v=$(total "${Q[$k]}")
            [ "$v" = none ] && { echo "$k none"; return; }
            sum[$k]=$(awk -v a="${sum[$k]:-0}" -v b="$v" 'BEGIN { print a + b }')
          done
          v=$(total 'db_pool_waiting_queries'); [ "$v" = none ] && v=0
          sum[queue]=$(awk -v a="${sum[queue]:-0}" -v b="$v" 'BEGIN { print a + b }')
          sleep 3
        done
        for k in utilisation saturation errors queue; do
          printf '%s %s\n' "$k" "$(awk -v s="${sum[$k]}" 'BEGIN { printf "%.3f", s / 4 }')"
        done
      }
      get() { awk -v k="$1" '$1 == k { print $2 }' <<<"$2"; }
      gt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'; }

      # Healthy: the lock released, long enough for every window to forget it.
      rm -f /obs/run/db.fault
      echo "measuring db healthy..."
      sleep 40
      h=$(measure)
      if [ "$(awk '$2 == "none"' <<<"$h")" ]; then
        k=$(awk '$2 == "none" { print $1 }' <<<"$h")
        echo "not yet: use-$k.promql returns no data. Try it with promq."
        exit 1
      fi

      # Saturated: the lock held again, and six more clients queueing for it.
      touch /obs/run/db.fault
      for _ in 1 2 3 4 5 6; do
        ( while :; do curl -s -o /dev/null --max-time 5 http://db:8080/query || true; done ) &
        pids+=($!)
      done
      echo "measuring db saturated..."
      sleep 25
      s=$(measure)
      kill "${pids[@]}" 2>/dev/null || true
      pids=()
      if [ "$(awk '$2 == "none"' <<<"$s")" ]; then
        k=$(awk '$2 == "none" { print $1 }' <<<"$s")
        echo "not yet: use-$k.promql returns no data while db is saturated."
        exit 1
      fi

      printf '               %-12s %-12s %s\n' utilisation saturation errors
      printf '  healthy      %-12s %-12s %s\n' "$(get utilisation "$h")" "$(get saturation "$h")" "$(get errors "$h")"
      printf '  saturated    %-12s %-12s %s\n' "$(get utilisation "$s")" "$(get saturation "$s")" "$(get errors "$s")"
      echo "  (queries waiting for a db connection meanwhile: $(get queue "$h") healthy, $(get queue "$s") saturated)"
      echo

      uh=$(get utilisation "$h"); us=$(get utilisation "$s")
      sh=$(get saturation "$h"); ss=$(get saturation "$s"); queue=$(get queue "$s")
      eh=$(get errors "$h"); es=$(get errors "$s")

      if gt "$us" 1.05; then
        echo "not yet: utilisation reads $us. Utilisation is the fraction of a resource's capacity in"
        echo "use, between 0 and 1. A count of busy units means nothing until you divide it by how"
        echo "many there are."
        exit 1
      fi
      if ! gt "$us" 0.7; then
        echo "not yet: utilisation reads $us while db could not serve its queries fast enough. The"
        echo "resource behind this outage was fully in use; this query measures one that was not."
        echo "Look at everything db exposes (curl -s db:9101/metrics), not only CPU and memory."
        exit 1
      fi
      if gt "$uh" 0.5; then
        echo "not yet: utilisation reads $uh with db healthy, nearly as high as saturated ($us)."
        echo "It should show how much of the resource is in use right now."
        exit 1
      fi
      if ! gt "$ss" 0.5; then
        echo "not yet: saturation reads $ss while $queue queries on average were waiting for db. It"
        echo "did not move when db saturated, so it measures something else."
        exit 1
      fi
      if ! gt "$ss" "$(awk -v q="$queue" 'BEGIN { print q / 2 }')"; then
        echo "not yet: saturation reads $ss while $queue queries on average were waiting for a"
        echo "connection. That looks like how much of the resource is busy, which is utilisation,"
        echo "and it stops growing at 100%. Saturation is the extra work queued behind it, and it"
        echo "keeps growing with the load."
        exit 1
      fi
      if gt "$sh" 0.2; then
        echo "not yet: saturation reads $sh with db healthy and nothing waiting. Saturation is work"
        echo "that cannot be served yet and queues; it should be about zero when nothing queues."
        exit 1
      fi
      if ! gt "$es" 0.05; then
        echo "not yet: errors reads $es while db was refusing queries because no connection came"
        echo "free. It has to count those refusals."
        exit 1
      fi
      if ! gt "$es" "$(awk -v h="$eh" 'BEGIN { print h * 3 }')" || gt "$eh" 0.05; then
        echo "not yet: errors reads $eh with db healthy and nothing failing ($es saturated). A counter's"
        echo "raw value is everything since the process started; errors here are a rate, so take"
        echo "rate() or increase() of it."
        exit 1
      fi

      echo "PASS — db's connection pool: fully in use, queries queueing for it, and refusals when"
      echo "none came free. Its CPU never showed any of it."
---
