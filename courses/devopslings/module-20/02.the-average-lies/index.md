---
kind: lesson
title: "The average is green"
description: |
  The profile API's average latency is 230ms against a 300ms target, and the
  dashboard has been green all week. Support has a queue of users who cannot
  load their profile. Find out from the latency distribution how many users
  the average is hiding.
name: the-average-lies
slug: the-average-lies
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
      set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-20/*.the-average-lies
      lesson=$1
      docker compose exec -T box obs-reset >/dev/null
      # gateway-exporter runs whatever /obs/apps/gateway_exporter.py is, and
      # obs-reset puts the stub back, so the next lesson starts without it.
      docker compose exec -T box sh -c 'cat > /obs/apps/gateway_exporter.py' < "$lesson/files/profile.py"
      docker compose exec -T box bash -euo pipefail -c '
        . /usr/local/lib/obs.sh
        cat >> /obs/prometheus/prometheus.yml <<YML

        - job_name: profile
          static_configs:
            - targets: ["gateway-exporter:9400"]
      YML
        rm -f /obs/answers/average.txt
        chmod -R a+rwX /obs/answers
        obs_reload >/dev/null
        prom_wait "sum(rate(profile_request_duration_seconds_count[1m])) > 0" 90'
      echo "scenario ready — the profile API's latency is the histogram"
      echo "profile_request_duration_seconds in Prometheus (job=\"profile\")."
      echo "Write your answers in /obs/answers/average.txt."

  verify_done:
    timeout_seconds: 60
    run: |
      . /usr/local/lib/obs.sh
      ans=/obs/answers/average.txt
      field() { grep -E "^$1=" "$ans" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d ' %\r' || true; }
      num() { [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]; }
      mean=$(field mean_ms); users=$(field affected_users_pct)
      if ! num "$mean" || ! num "$users"; then
        echo "not yet: $ans needs mean_ms=<n> and affected_users_pct=<n>, one per line."
        exit 1
      fi
      M=profile_request_duration_seconds
      ref_mean=$(prom_val "1000 * sum(rate(${M}_sum[1m])) / sum(rate(${M}_count[1m]))")
      ref_slow=$(prom_val "100 * (1 - sum(rate(${M}_bucket{le=~\"1|1.0\"}[1m])) / sum(rate(${M}_count[1m])))")
      ref_band=$(prom_val "100 * (sum(rate(${M}_bucket{le=~\"2|2.0\"}[1m])) - sum(rate(${M}_bucket{le=~\"1|1.0\"}[1m]))) / sum(rate(${M}_count[1m]))")
      if [ -z "$ref_mean" ] || [ -z "$ref_slow" ]; then
        echo "not yet: Prometheus has no recent data for $M. Rerun the lesson's init."
        exit 1
      fi
      close() { awk -v a="$1" -v b="$2" -v t="$3" 'BEGIN { exit !(a - b <= t && b - a <= t) }'; }
      if ! close "$mean" "$ref_mean" "$(awk -v r="$ref_mean" 'BEGIN { print r * 0.1 }')"; then
        echo "not yet: mean_ms=$mean, but the mean over the last minute is about $(printf '%.0f' "$ref_mean")ms."
        echo "A histogram's mean is its _sum divided by its _count, both as rates over a window."
        exit 1
      fi
      if close "$users" "$ref_slow" 0.6; then
        echo "PASS — the mean is ${mean}ms, under target, and ${users}% of users wait over a second on every request."
        exit 0
      fi
      if close "$users" 0 0.05; then
        echo "not yet: affected_users_pct=0. The mean is under target; that says nothing about how"
        echo "the requests are spread around it. Look at the buckets: how many requests take over 1s?"
      elif close "$users" "$(awk -v s="$ref_slow" 'BEGIN { print 100 - s }')" 1; then
        echo "not yet: affected_users_pct=$users is the share of requests that finished WITHIN a second:"
        echo "bucket le=\"1.0\" counts every request at or under 1s. The slow ones are the rest."
      elif close "$users" "$ref_band" 0.6; then
        echo "not yet: affected_users_pct=$users counts only the requests between 1s and 2s. Buckets are"
        echo "cumulative and the slow requests run past 2s; count everything above le=\"1.0\"."
      elif close "$users" 5 0.1; then
        echo "not yet: affected_users_pct=5. A p95 over a second says at least 5% are slow, not how many."
        echo "Count them from the buckets."
      elif awk -v u="$users" 'BEGIN { exit !(u > 0 && u < 1) }'; then
        echo "not yet: affected_users_pct=$users looks like a fraction. Give it as a percentage."
      else
        echo "not yet: affected_users_pct=$users. From the buckets, what share of requests takes over"
        echo "a second? Each user's requests all go to the same shard, so that is the share of users."
      fi
      exit 1
---
