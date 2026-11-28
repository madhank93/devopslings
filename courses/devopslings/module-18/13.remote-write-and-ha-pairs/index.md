---
kind: lesson
title: "every request, counted twice"
description: |
  Two Prometheus replicas scrape the same targets so that losing one loses
  nothing, and both remote-write to Mimir. Long-term storage now reports
  twice the traffic there was. Label the pair so Mimir keeps one replica's
  samples, and keeps them when that replica dies.
name: remote-write-and-ha-pairs
slug: remote-write-and-ha-pairs
createdAt: "2026-11-22"
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
      for r in 2 3; do
        name=$([ "$r" = 2 ] && echo a || echo b)
        cat > "/obs/prometheus-$r/prometheus.yml" <<YML
      # Replica $name of the pair. Both scrape the same targets and write to Mimir.
      # After editing: curl -X POST prometheus-$r:9090/-/reload
      global:
        scrape_interval: 5s
        scrape_timeout: 4s
        external_labels:
          replica: $name

      scrape_configs:
        - job_name: loadgen
          static_configs:
            - targets: ["loadgen:9101"]
        - job_name: shop
          static_configs:
            - targets: ["shop:9101"]

      remote_write:
        - url: http://mimir:9009/api/v1/push
      YML
      done
      chmod -R a+rX /obs/prometheus-2 /obs/prometheus-3
      app_up mimir; app_up prometheus-2; app_up prometheus-3
      for _ in $(seq 1 90); do
        [ "$(curl -s --max-time 2 "$MIMIR/ready" || true)" = ready ] &&
          curl -sf --max-time 2 "$PROM2/-/ready" >/dev/null && curl -sf --max-time 2 "$PROM3/-/ready" >/dev/null && break
        sleep 1
      done
      echo "scenario ready: prometheus-2 (replica a) and prometheus-3 (replica b) scrape loadgen and"
      echo "shop and remote-write to Mimir. Compare one replica with long-term storage:"
      echo "  curl -s prometheus-2:9090/api/v1/query --data-urlencode 'query=sum(loadgen_requests_total)' | jq ."
      echo "  curl -s mimir:9009/prometheus/api/v1/query --data-urlencode 'query=sum(loadgen_requests_total)' | jq ."

  verify_done:
    timeout_seconds: 420
    run: |
      . /usr/local/lib/obs.sh
      trap 'app_up prometheus-2; app_up prometheus-3' EXIT
      app_up mimir; app_up prometheus-2; app_up prometheus-3
      for _ in $(seq 1 60); do
        [ "$(curl -s --max-time 2 "$MIMIR/ready" || true)" = ready ] &&
          curl -sf --max-time 2 "$PROM2/-/ready" >/dev/null && curl -sf --max-time 2 "$PROM3/-/ready" >/dev/null && break
        sleep 1
      done
      url_of() { [ "$1" = 2 ] && echo "$PROM2" || echo "$PROM3"; }
      q() { curl -s --max-time 10 "$1/api/v1/query" --data-urlencode "query=$2" | jq -r '.data.result[0].value[1] // empty' 2>/dev/null || true; }

      # The running config of each replica, not the file.
      declare -A cluster replica
      for r in 2 3; do
        u=$(url_of "$r")
        info=$(curl -s --max-time 10 "$u/api/v1/status/runtimeinfo" || true)
        if [ "$(jq -r '.data.reloadConfigSuccess' <<<"$info" 2>/dev/null || true)" != true ]; then
          echo "not yet: prometheus-$r rejected its last config and runs the one before. Check it with"
          echo "promtool check config /obs/prometheus-$r/prometheus.yml"
          exit 1
        fi
        loaded=$(date -d "$(jq -r '.data.lastConfigTime' <<<"$info")" +%s 2>/dev/null || echo 0)
        if [ "$(newest_mtime "/obs/prometheus-$r/prometheus.yml")" -gt "$loaded" ]; then
          echo "not yet: /obs/prometheus-$r/prometheus.yml changed after prometheus-$r loaded it."
          echo "curl -X POST prometheus-$r:9090/-/reload"
          exit 1
        fi
        cfg=$(curl -s --max-time 10 "$u/api/v1/status/config" | jq -r '.data.yaml' 2>/dev/null || true)
        read -r c rp rw < <(python3 -c '
      import sys, yaml
      c = yaml.safe_load(sys.stdin) or {}
      el = (c.get("global") or {}).get("external_labels") or {}
      rw = any("mimir" in w.get("url", "") for w in c.get("remote_write") or [])
      print(el.get("cluster", "-"), el.get("__replica__", "-"), int(rw))' <<<"$cfg")
        if [ "$rw" != 1 ]; then
          echo "not yet: prometheus-$r no longer writes to Mimir. Both replicas must, or losing the"
          echo "one that does loses the data the pair was there to keep."
          exit 1
        fi
        cluster[$r]=$c; replica[$r]=$rp
      done
      if [ "${cluster[2]}" = - ] || [ "${replica[2]}" = - ] || [ "${cluster[3]}" = - ] || [ "${replica[3]}" = - ]; then
        echo "not yet: Mimir's HA tracker reads two external labels from every sample: cluster (which"
        echo "pair) and __replica__ (which member). prometheus-2 sends cluster=${cluster[2]} __replica__=${replica[2]},"
        echo "prometheus-3 sends cluster=${cluster[3]} __replica__=${replica[3]} (- means missing)."
        exit 1
      fi
      if [ "${cluster[2]}" != "${cluster[3]}" ]; then
        echo "not yet: the replicas send different clusters (${cluster[2]}, ${cluster[3]}). The HA tracker"
        echo "deduplicates within a cluster; two clusters are two sources, and both are kept."
        exit 1
      fi
      if [ "${replica[2]}" = "${replica[3]}" ]; then
        echo "not yet: both replicas send __replica__=${replica[2]}. To the HA tracker they are one"
        echo "replica, so it accepts both streams and they collide sample by sample."
        exit 1
      fi

      elected() {
        curl -s --max-time 10 "$MIMIR/distributor/ha_tracker" | python3 -c '
      import re, sys
      rows = re.findall(r"<tr>(.*?)</tr>", sys.stdin.read(), re.S)
      for r in rows:
          td = re.findall(r"<td>(.*?)</td>", r)
          if len(td) >= 3 and td[1] == sys.argv[1]:
              print(td[2])' "${cluster[2]}" || true
      }
      # compare R — Mimir's sum of the counter against replica R's own.
      compare() {
        local own lts
        own=$(q "$(url_of "$1")" 'sum(loadgen_requests_total)')
        lts=$(q "$MIMIR/prometheus" "sum(loadgen_requests_total{cluster=\"${cluster[2]}\"})")
        python3 -c 'import sys; o, l = float(sys.argv[1] or 0), float(sys.argv[2] or 0); print("ok" if o > 0 and abs(l / o - 1) < 0.1 else "%.2f" % (l / o if o else 0))' "$own" "$lts"
      }

      sleep 20
      e=
      for _ in $(seq 1 30); do e=$(elected); [ -n "$e" ] && break; sleep 1; done
      if [ -z "$e" ]; then
        echo "not yet: Mimir's HA tracker has elected no replica for cluster ${cluster[2]}."
        echo "Look at http://localhost:19009/distributor/ha_tracker."
        exit 1
      fi
      if [ "$e" = "${replica[2]}" ]; then r=2; s=3; else r=3; s=2; fi
      res=$(compare "$r")
      if [ "$res" != ok ]; then
        echo "not yet: Mimir's sum(loadgen_requests_total) is ${res}x what prometheus-$r reports."
        exit 1
      fi
      echo "Mimir keeps replica $e, and its count matches prometheus-$r's own"

      echo "prometheus-$r (the elected replica) stops..."
      app_down "prometheus-$r"
      ok=
      for _ in $(seq 1 60); do
        sleep 2
        [ "$(elected)" = "${replica[$s]}" ] || continue
        sleep 15
        [ "$(compare "$s")" = ok ] && ok=1 && break
      done
      app_up "prometheus-$r"
      if [ -z "$ok" ]; then
        echo "not yet: with prometheus-$r stopped for two minutes, Mimir did not switch to"
        echo "prometheus-$s (elected now: $(elected)), or its count stopped matching ($(compare "$s"))."
        exit 1
      fi
      echo "  Mimir switched to replica ${replica[$s]}, and its count still matches"
      echo "PASS — one replica's samples per cluster, before and after a replica dies."
