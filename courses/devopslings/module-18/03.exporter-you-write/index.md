---
kind: lesson
title: "the payments gateway has no exporter, so write one"
description: |
  The payments gateway is a vendor product. It has a JSON status page and a
  log file, and no metrics endpoint. Write the exporter that turns its status
  page into Prometheus metrics, with the right types and help text, and that
  keeps answering when the gateway does not.
name: exporter-you-write
slug: exporter-you-write
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
      cat >> /obs/prometheus/prometheus.yml <<'YML'

        - job_name: gateway
          static_configs:
            - targets: ["gateway-exporter:9101"]
      YML
      obs-reload >/dev/null
      echo "scenario ready: the gateway's status page is http://gateway:8080/status."
      echo "Write the exporter in /obs/apps/gateway_exporter.py; saving it restarts it, and its"
      echo "output is in /obs/logs/gateway-exporter.log. Prometheus scrapes it as job=\"gateway\"."

  verify_done:
    timeout_seconds: 240
    run: |
      . /usr/local/lib/obs.sh
      EXP=http://gateway-exporter:9101/metrics
      STATUS=http://gateway:8080/status
      cleanup() { app_up gateway; rm -f /obs/run/gateway.slow; }
      trap cleanup EXIT
      cleanup

      obs_require_loaded || exit 1

      # A save restarts the exporter; let the restart and one scrape after it
      # land before judging, or the previous version is graded.
      edited=$(newest_mtime /obs/apps/gateway_exporter.py /obs/run/gateway-exporter.started)
      settle=$(( edited + 8 - $(date +%s) ))
      [ "$settle" -gt 0 ] && sleep "$settle"
      for _ in $(seq 1 20); do curl -sf --max-time 3 "$STATUS" >/dev/null && break; sleep 1; done

      # supervise restarts a dead exporter within a second or two, so a recent
      # start plus an exit line in the log means it is crashing.
      crashed() {
        local log started
        started=$(cat /obs/run/gateway-exporter.started 2>/dev/null || echo 0)
        [ $(( $(date +%s) - started )) -lt 10 ] || return 1
        log=$(tail -n 40 /obs/logs/gateway-exporter.log 2>/dev/null || true)
        grep -q 'exited with status' <<<"$log" || return 1
        echo "The exporter keeps crashing. The end of /obs/logs/gateway-exporter.log:"
        grep -v '^\[supervise\]' <<<"$log" | tail -n 8 | sed 's/^/  /'
      }
      last_error() {
        curl -s --max-time 10 "$PROM/api/v1/targets?scrapePool=gateway" \
          | jq -r '.data.activeTargets[0].lastError // empty' 2>/dev/null || true
      }

      if ! prom_wait 'up{job="gateway"} == 1' 20; then
        echo "not yet: Prometheus cannot scrape gateway-exporter:9101."
        if ! crashed; then
          echo "Nothing answers on port 9101. prometheus_client's start_http_server(9101) serves the"
          echo "metrics endpoint, and the process has to keep running after it starts it."
        fi
        exit 1
      fi

      out=$(curl -s --max-time 5 "$EXP" || true)
      lint=$(printf '%s\n' "$out" | promtool check metrics 2>&1 || true)
      if [ -n "$lint" ]; then
        echo "not yet: promtool check metrics finds problems in what the exporter serves:"
        printf '%s\n' "$lint" | head -n 8 | sed 's/^/  /'
        if grep -q 'help text' <<<"$lint"; then
          echo "Every metric needs help text that says what it measures."
        fi
        if grep -q '_total' <<<"$lint"; then
          echo "_total marks a counter. A count that only goes up has to be typed counter; a level"
          echo "that goes up and down is a gauge, and its name has no _total."
        fi
        exit 1
      fi

      types=$(awk '$1 == "#" && $2 == "TYPE" { print $3, $4 }' <<<"$out")
      type_of() {
        local t
        t=$(awk -v m="$1" '$1 == m { print $2; exit }' <<<"$types")
        [ -n "$t" ] || t=$(awk -v m="${1%_total}" '$1 == m { print $2; exit }' <<<"$types")
        printf '%s' "$t"
      }
      have=$(awk '$1 ~ /^gateway_/ { print $1 }' <<<"$types" | paste -sd, - || true)
      for m in gateway_payments_processed_total:counter gateway_payments_failed_total:counter \
               gateway_queue_depth:gauge gateway_up:gauge; do
        name=${m%%:*}; want=${m#*:}; got=$(type_of "$name")
        if [ -z "$got" ]; then
          echo "not yet: the exporter does not serve $name. It serves: ${have:-no gateway_* metrics}."
          exit 1
        fi
        if [ "$got" != "$want" ]; then
          echo "not yet: $name is a $got; it has to be a $want."
          if [ "$want" = counter ]; then
            echo "The gateway counts payments from installation and the count only goes up. Typed as a"
            echo "gauge, it tells every reader it may go down, and rate() or increase() on it comes back"
            echo "with a warning that it might not be a counter. prometheus_client's Counter can"
            echo "only be incremented, not set; a custom collector yielding CounterMetricFamily can report"
            echo "a count someone else keeps."
          else
            echo "It is a level that goes up and down, not a count of events."
          fi
          exit 1
        fi
      done

      # Values, side by side with the gateway's own, twice, ten seconds apart.
      value() {
        awk -v m="$1" '$1 == m || index($1, m "{") == 1 { s += $NF; f = 1 } END { if (f) printf "%.0f", s }' <<<"$2"
      }
      sample() {
        local e s
        e=$(curl -s --max-time 5 "$EXP" || true)
        s=$(curl -s --max-time 5 "$STATUS" || echo '{}')
        printf '%s %s %s %s\n' \
          "$(value gateway_payments_processed_total "$e")" "$(jq -r '.payments.processed // 0' <<<"$s")" \
          "$(value gateway_payments_failed_total "$e")" "$(jq -r '.payments.failed // 0' <<<"$s")"
      }
      read -r p1 sp1 f1 sf1 <<<"$(sample)"
      sleep 10
      read -r p2 sp2 f2 sf2 <<<"$(sample)"
      far() { awk -v a="${1:-0}" -v b="${2:-0}" -v t="$3" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d > t) }'; }
      echo "gateway's own counts: processed $sp2, failed $sf2"
      echo "exporter reports:     processed ${p2:-none}, failed ${f2:-none}"
      if [ "${p2:-0}" = "${p1:-0}" ] && [ $(( sp2 - sp1 )) -ge 10 ]; then
        echo "not yet: the gateway processed $(( sp2 - sp1 )) payments in ten seconds, and the exporter's"
        echo "gateway_payments_processed_total did not move. It has to read the status page on every"
        echo "scrape (or keep a fresh copy), not once when it starts."
        exit 1
      fi
      if far "$p2" "$sp2" 60 || far "$f2" "$sf2" 10; then
        if awk -v p="${p2:-0}" -v s="$sp2" 'BEGIN { exit !(p < s / 10) }'; then
          echo "not yet: the exporter says ${p2:-0} payments processed; the gateway says $sp2. The log file only"
          echo "holds the last minute or two (it is rotated every minute), and anything counted from it"
          echo "starts over whenever the exporter restarts. The gateway keeps the real count since"
          echo "installation on its status page."
        else
          echo "not yet: the exporter's counts do not match the gateway's status page. Report the"
          echo "numbers the gateway gives, each under the metric that names it."
        fi
        exit 1
      fi

      # The gateway goes away. The exporter must keep answering and say so.
      outage() {  # outage WHAT HOW-LONG-IT-SAID
        local up gu e
        up=$(prom_val 'up{job="gateway"}')
        gu=$(prom_val 'gateway_up{job="gateway"}')
        if [ "$up" != 1 ]; then
          e=$(last_error)
          echo "not yet: while the gateway $1, Prometheus could not scrape the exporter (${e:-no answer})."
          if [ "$2" = slow ]; then
            echo "The status page took 8 seconds to answer, and Prometheus gives up on a scrape after"
            echo "scrape_timeout, 4s here. An exporter that waits on its source longer than that loses"
            echo "the whole scrape. Give the fetch a timeout well under the scrape timeout."
          else
            crashed || true
            echo "A failed scrape marks the whole target down and every one of its series goes stale,"
            echo "including the one that would have said what is wrong. Catch the failure, keep serving,"
            echo "and report gateway_up 0."
          fi
          exit 1
        fi
        if [ "$gu" != 0 ]; then
          echo "not yet: while the gateway $1, the exporter answered and reported gateway_up ${gu:-(missing)}."
          echo "gateway_up has to be 0 whenever the status page did not answer, so an alert can fire"
          echo "on it and nobody mistakes old numbers for current ones."
          exit 1
        fi
        e=$(curl -s --max-time 6 "$EXP" || true)
        if [ "$(value gateway_payments_processed_total "$e")" = 0 ]; then
          echo "not yet: while the gateway $1, the exporter reported gateway_payments_processed_total 0."
          echo "To Prometheus a counter that drops to zero has reset: when the gateway comes back,"
          echo "increase() counts all 180,000-odd payments again as if they happened in that minute."
          echo "Leave the counters out while you do not know them; gateway_up says why."
          exit 1
        fi
      }
      recovered() {
        if ! prom_wait 'gateway_up{job="gateway"} == 1' 25; then
          echo "not yet: the gateway is back and answering, and gateway_up has not returned to 1."
          echo "The exporter has to recover by itself on the next scrape."
          exit 1
        fi
      }

      app_down gateway
      sleep 12
      outage "was down" down
      app_up gateway
      recovered

      touch /obs/run/gateway.slow
      sleep 14
      outage "took 8 seconds to answer" slow
      rm -f /obs/run/gateway.slow
      recovered

      echo "PASS — the exporter mirrors the gateway's counts as counters with help text, and when the"
      echo "gateway is down or too slow it still answers, with gateway_up 0."
---
