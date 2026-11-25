---
kind: lesson
title: "the batch job that died three days ago"
description: |
  The nightly batch job has been failing for three days, and its "last
  success" metric is still there, still the same, still not absent. The
  Pushgateway keeps whatever was pushed to it until someone deletes it. Alert
  on the job being late, not on the metric being gone.
name: pushgateway-ghosts
slug: pushgateway-ghosts
createdAt: "2026-11-22"
timingSensitive: true

sandbox:
  stack: obs-stack
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 120
    run: |
      obs-reset >/dev/null
      . /usr/local/lib/obs.sh
      cat >> /obs/prometheus/prometheus.yml <<'YML'

        # The Pushgateway's metrics carry the job and instance of whoever
        # pushed them; honor_labels keeps those instead of the gateway's own.
        - job_name: pushgateway
          honor_labels: true
          static_configs:
            - targets: ["pushgateway:9091"]
      YML
      cat > /obs/prometheus/rules/nightly.yml <<'YML'
      groups:
        - name: nightly
          rules:
            - alert: NightlyMissing
              expr: absent(nightly_last_success_timestamp_seconds{job="nightly"})
              for: 1m
              labels:
                severity: critical
              annotations:
                summary: the nightly job has not reported a success
      YML
      chmod a+r /obs/prometheus/rules/nightly.yml
      obs-reload >/dev/null
      app_up nightly
      for _ in $(seq 1 30); do
        curl -s --max-time 5 "$PUSHGW/api/v1/metrics" | jq -e '.data | length > 0' >/dev/null 2>&1 && break
        sleep 1
      done
      touch /obs/run/nightly.fault
      echo "scenario ready: the nightly job (one run every 20 seconds here) is failing; see"
      echo "/obs/logs/nightly.log. Its alert is /obs/prometheus/rules/nightly.yml."
      echo "  promq 'nightly_last_success_timestamp_seconds'"

  verify_done:
    timeout_seconds: 600
    run: |
      . /usr/local/lib/obs.sh
      trap 'rm -f /obs/run/nightly.fault' EXIT
      app_up nightly
      rm -f /obs/run/nightly.fault
      obs_require_loaded || exit 1

      firing() { prom_count 'ALERTS{alertstate="firing"}'; }
      paged() {
        sink_all | jq -r '[.[] | select(.payload.status == "firing") | .payload.alerts[]
          | select(.status == "firing") | .labels.alertname] | unique | join(", ")' 2>/dev/null || true
      }
      pushed_ago() { prom_val 'time() - max(push_time_seconds{job="nightly"})' | cut -d. -f1; }

      # Round 1: the job runs on schedule, and nothing may page.
      echo "the job runs normally..."
      for _ in $(seq 1 40); do a=$(pushed_ago); [ -n "$a" ] && [ "$a" -lt 15 ] && break; sleep 1; done
      for _ in $(seq 1 120); do [ "$(firing)" = 0 ] && break; sleep 1; done
      sleep 5
      sink_reset
      sleep 75
      # An alert that never stops firing paged before the sink was reset, and
      # Alertmanager does not repeat it within the hour.
      p=$(paged)
      [ -n "$p" ] || p=$(prom_query 'ALERTS{alertstate="firing"}' |
        jq -r '[.data.result[].metric.alertname] | unique | join(", ")' 2>/dev/null || true)
      if [ -n "$p" ]; then
        echo "not yet: the job ran on schedule for 75 seconds and this paged: $p."
        echo "A run lands every 20 to 26 seconds here; a threshold at or under that fires between"
        echo "two healthy runs. Leave room for at least one late run."
        exit 1
      fi
      echo "  nothing paged"

      # Round 2: the job starts failing, and stops pushing.
      echo "the job starts failing..."
      touch /obs/run/nightly.fault
      p=
      for _ in $(seq 1 120); do p=$(paged); [ -n "$p" ] && break; sleep 1; done
      ago=$(pushed_ago)
      pending=$(prom_query 'ALERTS{alertstate="pending"}' | jq -r '[.data.result[].metric.alertname] | unique | join(", ")' 2>/dev/null || true)
      rm -f /obs/run/nightly.fault
      if [ -z "$p" ]; then
        echo "not yet: the job has failed every run for two minutes and nothing paged."
        if [ -n "$pending" ]; then
          echo "$pending noticed and was still pending. A job two runs late is already news; a for:"
          echo "that long on top of the threshold keeps it quiet for minutes more."
        elif [ "$(prom_count 'nightly_last_success_timestamp_seconds{job="nightly"}')" -gt 0 ]; then
          echo "nightly_last_success_timestamp_seconds is still there: the Pushgateway serves the last"
          echo "value it was given until something deletes it, so absent() of it never fires and"
          echo "it never goes stale. The last push was ${ago:-?} seconds ago; that age is what changes."
        fi
        exit 1
      fi
      echo "  paged: $p"
      echo "PASS — a job that stops pushing pages, and a job on schedule does not."
