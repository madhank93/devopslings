---
kind: lesson
title: "Paged for a busy CPU, silent for a broken cart"
description: |
  ShopCPUOver80 woke someone at 03:10 for the nightly index rebuild, which
  hurt nobody. Two days later the cart failed for twenty minutes at a few
  percent CPU, and nothing paged. Replace the alert with one that fires when
  customers are hurt, whatever the cause, and stays quiet when they are not.
name: cpu-over-eighty
slug: cpu-over-eighty
createdAt: "2026-11-16"
timingSensitive: true

sandbox:
  stack: obs-stack
  service: box

tasks:
  init_scenario:
    init: true
    service: host
    timeout_seconds: 180
    run: |
      set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-20/*.cpu-over-eighty
      lesson=$1
      docker compose exec -T box obs-reset >/dev/null
      # obs-reset puts the baseline shop back, so the next lesson starts without
      # the rebuild thread.
      docker compose exec -T box sh -c 'cat > /obs/apps/shop.py' < "$lesson/files/shop.py"
      docker compose exec -T box bash -euo pipefail -c '
        . /usr/local/lib/obs.sh
        cat > /obs/prometheus/rules/capacity.yml <<YML
      groups:
        - name: capacity
          rules:
            - alert: ShopCPUOver80
              expr: rate(process_cpu_seconds_total{job="shop"}[30s]) > 0.8
              for: 30s
              labels:
                severity: page
              annotations:
                summary: shop is using more than 80% of a core
      YML
        chmod -R a+rX /obs/prometheus
        obs_reload >/dev/null'
      echo "scenario ready — the alert is in /obs/prometheus/rules/capacity.yml; every alert pages."
      echo "Pages land in the sink:"
      echo "  curl -s sink:8080/notifications | jq '.[] | {path, status: .payload.status, alerts: [.payload.alerts[].labels.alertname]}'"
      echo "Start and stop the rebuild:  touch /obs/run/shop.rebuild   /   rm /obs/run/shop.rebuild"

  verify_done:
    timeout_seconds: 900
    run: |
      . /usr/local/lib/obs.sh
      cleanup() { rm -f /obs/run/shop.rebuild /obs/run/shop.fault /obs/run/db.fault; }
      trap cleanup EXIT
      cleanup

      obs_require_loaded || exit 1
      n=$(obs_active_silences)
      if [ "$n" -gt 0 ]; then
        echo "not yet: $n silence(s) are active in Alertmanager, and a silence hides the next real page"
        echo "too. Expire it and fix the alert instead."
        exit 1
      fi
      rules=$(curl -s --max-time 10 "$PROM/api/v1/rules?type=alert" | jq -r '[.data.groups[]?.rules[]?] | length' 2>/dev/null || echo 0)
      if [ "$rules" = 0 ]; then
        echo "not yet: Prometheus has no alert rules at all. Nothing pages when the cart breaks either."
        exit 1
      fi

      # What customers saw over the last minute, for the messages below.
      seen() {
        local e p
        e=$(prom_val 'sum(rate(shop_http_requests_total{code="500"}[1m])) / sum(rate(shop_http_requests_total[1m]))')
        p=$(prom_val 'histogram_quantile(0.99, sum by (le) (rate(shop_http_request_duration_seconds_bucket[1m])))')
        printf '%s%% of shop requests failed, p99 %sms' "$(awk -v e="${e:-0}" 'BEGIN { printf "%.1f", 100 * e }')" \
          "$(awk -v p="${p:-0}" 'BEGIN { printf "%d", 1000 * p }')"
      }
      alerts_in() { prom_query "ALERTS{alertstate=\"$1\"}" | jq -r '[.data.result[].metric.alertname] | unique | join(", ")' 2>/dev/null || true; }
      firing() { alerts_in firing; }
      # An alert that matched but is still waiting out its for: never reached the pager.
      still_pending() {
        local pd
        pd=$(alerts_in pending)
        [ -n "$pd" ] || return 1
        echo "$pd matched, but was still pending when the round ended: its for: is longer than"
        echo "customers should be failing before anyone hears. Shorten it to a minute or less."
      }
      paged() { sink_all | jq -r '[.[] | select(.path == "/pager" and .payload.status == "firing") | .payload.alerts[]
        | select(.status == "firing") | .labels.alertname] | unique | join(", ")' 2>/dev/null || true; }
      # Wait out the last round: nothing firing, and no failed request left in
      # the one-minute windows an alert might read.
      settle() {
        local fails
        for _ in $(seq 1 150); do
          fails=$(prom_val 'sum(increase(shop_http_requests_total{code="500"}[90s]))')
          [ -z "$(firing)" ] && awk -v f="${fails:-0}" 'BEGIN { exit !(f < 0.5) }' && break
          sleep 1
        done
        sleep 8
        sink_reset
      }
      # wait_page SECONDS — succeed as soon as something pages.
      wait_page() {
        for _ in $(seq 1 "$1"); do
          [ -n "$(paged)" ] && return 0
          sleep 1
        done
        return 1
      }

      # Nothing is wrong yet: nothing may be firing.
      settle
      already=$(firing)
      if [ -n "$already" ]; then
        echo "not yet: with nothing broken ($(seen)), these alerts are firing: $already."
        echo "An alert that fires on a normal day pages every night. Set the threshold from what shop"
        echo "does when it is healthy."
        exit 1
      fi

      # Round 1: the rebuild burns a core for 100 seconds. Customers do not notice.
      touch /obs/run/shop.rebuild
      wait_page 100 || true
      rm -f /obs/run/shop.rebuild
      p=$(paged)
      if [ -n "$p" ]; then
        echo "not yet: during the index rebuild, $p paged. Customers were fine: $(seen)."
        echo "shop was busy, and busy is not broken. Page on what customers get — failed requests,"
        echo "slow requests — not on how hard shop works to give it to them."
        exit 1
      fi
      echo "rebuild: a core busy for 100s, no page ($(seen))"

      # Round 2: a migration holds db's lock. /cart and /orders fail, CPU idles.
      settle
      touch /obs/run/db.fault
      if ! wait_page 150; then
        s=$(seen); f=$(firing); pd=$(still_pending || true)
        rm -f /obs/run/db.fault
        echo "not yet: db was locked for 150 seconds and nothing paged. Customers saw: $s."
        [ -n "$pd" ] && { echo "$pd"; exit 1; }
        echo "Firing in Prometheus: ${f:-nothing}. shop's CPU was near idle: the outage did no work."
        echo "The alert has to watch what customers get."
        exit 1
      fi
      echo "db locked: paged ($(paged))"
      rm -f /obs/run/db.fault

      # Round 3: shop's own bug fails 30% of requests, fast. db is healthy.
      settle
      echo 0.3 > /obs/run/shop.fault
      if ! wait_page 150; then
        s=$(seen); f=$(firing); pd=$(still_pending || true)
        rm -f /obs/run/shop.fault
        echo "not yet: shop failed requests for 150 seconds with db healthy, and nothing paged."
        echo "Customers saw: $s."
        [ -n "$pd" ] && { echo "$pd"; exit 1; }
        echo "Firing: ${f:-nothing}. These failures come back fast, so an alert on latency, or on one"
        echo "cause such as db, never sees them. Page on the share of requests that fail as well."
        exit 1
      fi
      echo "shop bug: paged ($(paged))"
      rm -f /obs/run/shop.fault
      settle

      echo
      echo "PASS — quiet through a core's worth of rebuild, and paged both when db broke the cart"
      echo "and when shop broke on its own."
---
