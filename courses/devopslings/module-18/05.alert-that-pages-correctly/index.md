---
kind: lesson
title: "the database went down, and the pager stayed quiet"
description: |
  db stopped answering for ten minutes last night. Every alert fired, and the
  pager never went off: the critical alerts were filed as tickets. Fix the
  routing, and the obvious fix pages three times for one outage. Make one
  outage send one page, naming its cause.
name: alert-that-pages-correctly
slug: alert-that-pages-correctly
createdAt: "2026-10-15"
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

      cat > /obs/prometheus/rules/shop.yml <<'YML'
      groups:
        - name: shop
          rules:
            - alert: DatabaseDown
              expr: up{job="db"} == 0
              for: 10s
              # Stays firing while shop recovers, so the alerts it inhibits
              # stay quiet through the recovery too.
              keep_firing_for: 45s
              labels:
                severity: critical
                service: db
              annotations:
                summary: db is not answering

            - alert: ShopErrorRate
              expr: |
                sum(rate(shop_http_requests_total{code="500"}[20s]))
                  / sum(rate(shop_http_requests_total[20s])) > 0.1
              for: 20s
              labels:
                severity: critical
                service: shop
              annotations:
                summary: more than 10% of shop requests are failing

            - alert: ShopCartFailing
              expr: sum(rate(shop_http_requests_total{route="/cart",code="500"}[20s])) > 0.1
              for: 20s
              labels:
                severity: critical
                service: shop
              annotations:
                summary: customers cannot load their cart

        - name: worker
          rules:
            - alert: WorkerQueueDepthHigh
              expr: max(worker_queue_depth) > 30
              labels:
                severity: warning
                service: worker
              annotations:
                summary: jobs are queueing
      YML

      cat > /obs/alertmanager/alertmanager.yml <<'YML'
      route:
        receiver: tickets
        group_by: [alertname]
        group_wait: 2s
        group_interval: 5s
        repeat_interval: 1h
        routes:
          - matchers: ['severity="page"']
            receiver: pager

      receivers:
        # Wakes someone up.
        - name: pager
          webhook_configs:
            - url: http://sink:8080/pager
        # Read during working hours.
        - name: tickets
          webhook_configs:
            - url: http://sink:8080/tickets
      YML
      chmod -R a+rX /obs/prometheus /obs/alertmanager
      obs-reload >/dev/null
      echo "scenario ready: alert rules in /obs/prometheus/rules/shop.yml,"
      echo "routing in /obs/alertmanager/alertmanager.yml. Notifications land in the sink:"
      echo "  curl -s sink:8080/notifications | jq '.[] | {path, status: .payload.status, alerts: [.payload.alerts[].labels.alertname]}'"

  verify_done:
    timeout_seconds: 600
    run: |
      . /usr/local/lib/obs.sh
      # An unrelated outage the check reports straight to Alertmanager, to show
      # whether a db outage hides it.
      other() {  # other ENDS-AT
        curl -s --max-time 10 -X POST -H 'Content-Type: application/json' "$AM/api/v2/alerts" -d "[{
          \"labels\": {\"alertname\": \"PaymentProviderDown\", \"severity\": \"critical\", \"service\": \"payments\"},
          \"annotations\": {\"summary\": \"the payment provider refuses every charge\"},
          \"endsAt\": \"$1\"}]" >/dev/null || true
      }
      cleanup() { app_up db; rm -f /obs/run/shop.fault; other "$(date -u +%FT%TZ)"; }
      trap cleanup EXIT
      cleanup

      obs_require_loaded || exit 1
      n=$(obs_active_silences)
      if [ "$n" -gt 0 ]; then
        echo "not yet: $n silence(s) are active in Alertmanager. A silence hides a page for as long as"
        echo "it lasts, including the next real outage. Expire it (amtool silence query / expire"
        echo "--alertmanager.url=http://alertmanager:9093) and fix the routing instead."
        exit 1
      fi

      # Routing, as the running Alertmanager resolves each rule's labels.
      rules=$(curl -s --max-time 10 "$PROM/api/v1/rules?type=alert" || echo '{}')
      labels_of() {
        jq -r --arg a "$1" '[.data.groups[]?.rules[] | select(.name == $a)][0].labels // empty
          | to_entries | map("\(.key)=\(.value)") | join(" ")' <<<"$rules" 2>/dev/null || true
      }
      route_of() {
        # shellcheck disable=SC2086
        amtool config routes test --alertmanager.url="$AM" alertname="$1" $(labels_of "$1") 2>/dev/null | tr '\n' ' ' || true
      }
      for a in DatabaseDown ShopErrorRate ShopCartFailing WorkerQueueDepthHigh; do
        if [ -z "$(labels_of "$a")" ]; then
          echo "not yet: Prometheus has no alert rule named $a any more. Each of the four alerts"
          echo "watches something real; the fix is in where they go, not whether they exist."
          exit 1
        fi
      done
      for a in DatabaseDown ShopErrorRate ShopCartFailing; do
        r=$(route_of "$a")
        if ! grep -qw pager <<<"$r"; then
          echo "not yet: $a, with labels $(labels_of "$a"), is routed to: ${r:-nothing}."
          echo "It is critical and has to reach the pager. Check it with:"
          echo "  amtool config routes test --alertmanager.url=http://alertmanager:9093 $(labels_of "$a")"
          exit 1
        fi
      done
      r=$(route_of WorkerQueueDepthHigh)
      if grep -qw pager <<<"$r"; then
        echo "not yet: WorkerQueueDepthHigh is a warning, and it routes to the pager ($r)."
        echo "A warning is read in working hours; it goes to tickets."
        exit 1
      fi
      if ! grep -qw tickets <<<"$r"; then
        echo "not yet: WorkerQueueDepthHigh routes to: ${r:-nothing}. Warnings still go to tickets."
        exit 1
      fi

      # Behaviour: break something, and count what reaches the pager from the
      # moment it breaks until every alert it caused has resolved.
      # The longest group_wait in the running config, in whole seconds
      # (Alertmanager's default is 30s).
      gw=$(curl -s --max-time 10 "$AM/api/v2/status" | jq -r '.config.original' | python3 -c '
      import re, sys
      unit = {"ms": 0.001, "s": 1, "m": 60, "h": 3600}
      waits = [sum(float(n) * unit[u] for n, u in re.findall(r"([0-9.]+)(ms|s|m|h)", v))
               for v in re.findall(r"group_wait:\s*[\x27\x22]?([0-9a-z.]+)", sys.stdin.read())]
      print(int(max(waits or [30]) + 0.999))' 2>/dev/null || echo 30)
      if [ "$gw" -gt 60 ]; then
        echo "not yet: group_wait is ${gw}s somewhere in the routing tree, so the first page of an"
        echo "outage arrives at least that long after it starts. Batch an outage's alerts in"
        echo "seconds, not minutes."
        exit 1
      fi

      settle() {
        for _ in $(seq 1 120); do
          [ "$(prom_count 'ALERTS{alertstate="firing",severity="critical"}')" = 0 ] && break
          sleep 1
        done
        # A reload rebuilds Alertmanager's groups from the alerts it holds,
        # including the last round's resolved ones. Those groups flush once,
        # group_wait later; wait that out so this round starts from new groups.
        curl -s --max-time 20 -X POST "$AM/-/reload" >/dev/null || true
        sleep $(( gw + 3 ))
        sink_reset
      }
      # A page is a notification that brings a firing alert the pager has not
      # already been told about this round. Updates that only add resolutions
      # (webhooks send them by default) wake nobody.
      pages() {
        sink_all | jq -c --argjson t0 "$t0" '[.[] | select(.path == "/pager")
          | {t: ((.at - $t0) | floor), alerts: ([.payload.alerts[] | select(.status == "firing") | .labels.alertname] | unique)}]
          | reduce .[] as $n ({seen: [], out: []};
              if ($n.alerts - .seen | length) > 0 then .out += [$n] | .seen += $n.alerts else . end)
          | .out' 2>/dev/null || echo '[]'
      }
      show() { jq -r '.[] | "  +\(.t)s  \(.alerts | join(", "))"' <<<"$1"; }

      # Round 1: db goes down. shop's cart and orders pages fail with it.
      settle
      t0=$(date +%s)
      app_down db
      for _ in $(seq 1 90); do
        [ "$(jq length <<<"$(pages)")" -gt 0 ] && break
        sleep 1
      done
      if [ "$(jq length <<<"$(pages)")" = 0 ]; then
        firing=$(prom_query 'ALERTS{severity="critical"}' | jq -r '[.data.result[].metric | "\(.alertname) (\(.alertstate))"] | join(", ")' 2>/dev/null || true)
        echo "not yet: db was down for 90 seconds and nothing reached the pager."
        echo "Critical alerts in Prometheus: ${firing:-none}."
        if [ -n "$firing" ]; then
          echo "They reached Alertmanager. Look at what it did with them: amtool alert query shows"
          echo "each alert and whether something inhibits it, and amtool config routes test shows"
          echo "where its labels are routed."
        fi
        exit 1
      fi
      # While db is down, a second, unrelated critical outage starts.
      other "$(date -u -d '+5 min' +%FT%TZ)"
      paid=no
      for _ in $(seq 1 $(( gw + 20 ))); do
        if jq -e 'any(.[].alerts[]; . == "PaymentProviderDown")' <<<"$(pages)" >/dev/null; then paid=yes; break; fi
        sleep 1
      done
      other "$(date -u +%FT%TZ)"
      if [ "$paid" = no ]; then
        echo "not yet: while db was down, an unrelated critical alert arrived, PaymentProviderDown"
        echo "(service=payments, sent to Alertmanager by the check), and it never reached the pager."
        echo "db being down explains shop's errors, not every other outage. Make the inhibit rule"
        echo "target only the alerts DatabaseDown explains."
        exit 1
      fi
      sleep 10
      app_up db
      settle_wait() {
        for _ in $(seq 1 120); do
          [ "$(prom_count 'ALERTS{alertstate="firing",severity="critical"}')" = 0 ] && break
          sleep 1
        done
        sleep 8
      }
      settle_wait
      p1=$(pages | jq -c '[.[] | .alerts -= ["PaymentProviderDown"] | select(.alerts | length > 0)]')
      echo "db outage, pages received:"; show "$p1"
      if [ "$(jq length <<<"$p1")" -gt 1 ]; then
        echo "not yet: one outage, $(jq length <<<"$p1") pages. db was the only thing broken; shop failed because"
        if jq -e '[.[].alerts[]] | any(. == "ShopErrorRate" or . == "ShopCartFailing")' <<<"$p1" >/dev/null; then
          echo "it cannot reach db. Its alerts are symptoms of DatabaseDown, and they paged anyway."
          echo "An inhibit rule lets a firing alert mute the alerts it explains."
        else
          echo "it cannot reach db, and DatabaseDown paged more than once. Look at the times above"
          echo "against group_wait, group_interval and repeat_interval."
        fi
        exit 1
      fi
      if ! jq -e '.[0].alerts | index("DatabaseDown")' <<<"$p1" >/dev/null; then
        echo "not yet: the page did not name DatabaseDown, the cause. Whoever is woken up has to"
        echo "see what broke, not only what it broke."
        exit 1
      fi
      if jq -e '.[0].alerts | any(. == "ShopErrorRate" or . == "ShopCartFailing")' <<<"$p1" >/dev/null; then
        echo "not yet: one page, and it lists shop's alerts next to DatabaseDown. shop's errors are"
        echo "what a db outage looks like from shop; they add nothing to the page and make it read"
        echo "like two problems. Inhibit them while DatabaseDown fires."
        exit 1
      fi

      # Round 2: shop breaks on its own. db is fine, so nothing inhibits it.
      settle
      t0=$(date +%s)
      touch /obs/run/shop.fault
      for _ in $(seq 1 90); do
        [ "$(jq length <<<"$(pages)")" -gt 0 ] && break
        sleep 1
      done
      if [ "$(jq length <<<"$(pages)")" = 0 ]; then
        state=$(prom_query 'ALERTS{service="shop"}' | jq -r '[.data.result[].metric | "\(.alertname) (\(.alertstate))"] | join(", ")' 2>/dev/null || true)
        echo "not yet: shop failed most of its requests for 90 seconds, with db healthy, and nothing"
        echo "reached the pager. shop's alerts in Prometheus: ${state:-none}."
        if grep -q pending <<<"$state"; then
          echo "Pending means the condition is true and its for: has not elapsed yet."
        elif [ -n "$state" ]; then
          echo "They fired. Is an inhibit rule muting them when DatabaseDown is not firing?"
        fi
        exit 1
      fi
      sleep 20
      rm -f /obs/run/shop.fault
      settle_wait
      p2=$(pages)
      echo "shop bug, pages received:"; show "$p2"
      if [ "$(jq length <<<"$p2")" -gt 1 ]; then
        echo "not yet: one shop outage, $(jq length <<<"$p2") pages. ShopErrorRate and ShopCartFailing describe the"
        echo "same broken service. Alertmanager groups alerts that share the labels in group_by"
        echo "into one notification; group_by: [alertname] gives every alert its own page."
        exit 1
      fi
      if ! jq -e '.[0].alerts | any(. == "ShopErrorRate" or . == "ShopCartFailing")' <<<"$p2" >/dev/null; then
        echo "not yet: the page during shop's own outage did not include shop's alerts."
        exit 1
      fi

      echo
      echo "PASS — a db outage sends one page naming DatabaseDown, a shop bug sends one page"
      echo "naming shop, and warnings stay in tickets."
---
