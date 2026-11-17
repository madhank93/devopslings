---
kind: lesson
title: "The page that nobody owns"
description: |
  An alert fired at 02:10 for ledger, and it paged the platform team, as every
  alert does. They spent forty minutes finding out whose ledger is, using a
  spreadsheet that was wrong. Route each alert to the team that owns the
  service, from metadata that lives with the service, and stop a service with
  no owner at the pipeline.
name: ownership-metadata
slug: ownership-metadata
createdAt: "2026-11-16"

sandbox:
  stack: obs-stack
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      obs-reset >/dev/null
      rm -rf /obs/services /obs/platform
      mkdir -p /obs/services /obs/platform

      # The model. The grader refuses to run against an edited copy.
      cat > /obs/apps/gateway_exporter.py <<'PY'
      """platform-sim: the services' traffic and the service catalogue, on :9101.

      A model, not a service. Every directory under /obs/services holding a
      service.yaml is a service. service_info{service, team} carries the owner
      that file names, read on every scrape. A service's requests fail at 30%
      while /obs/run/sim-<service>.fault exists, and at 0.2% otherwise.
      """
      import glob
      import os
      import random
      import threading
      import time

      import yaml
      from prometheus_client import start_http_server
      from prometheus_client.core import REGISTRY, CounterMetricFamily, GaugeMetricFamily

      lock = threading.Lock()
      requests = {}  # (service, code) -> count


      def services():
          out = {}
          for f in sorted(glob.glob("/obs/services/*/service.yaml")):
              name = os.path.basename(os.path.dirname(f))
              try:
                  meta = yaml.safe_load(open(f)) or {}
              except Exception:
                  meta = {}
              owner = meta.get("owner") if isinstance(meta, dict) else None
              out[name] = str(owner) if owner else ""
          return out


      class Catalogue:
          def collect(self):
              info = GaugeMetricFamily("service_info", "One series per service; team is its owner.", labels=["service", "team"])
              for name, team in services().items():
                  info.add_metric([name, team], 1)
              yield info
              total = CounterMetricFamily("http_requests", "Requests served, by service and status code.", labels=["service", "code"])
              with lock:
                  for (name, code), n in sorted(requests.items()):
                      total.add_metric([name, code], n)
              yield total


      REGISTRY.register(Catalogue())
      start_http_server(9101)
      while True:
          for name in services():
              bad = 0.3 if os.path.exists(f"/obs/run/sim-{name}.fault") else 0.002
              with lock:
                  for _ in range(20):
                      code = "500" if random.random() < bad else "200"
                      requests[(name, code)] = requests.get((name, code), 0) + 1
          time.sleep(0.5)
      PY

      svc() {  # svc NAME [OWNER]
        mkdir -p "/obs/services/$1"
        { echo "name: $1"
          [ -n "${2:-}" ] && echo "owner: $2"
          echo "tier: 1"
        } > "/obs/services/$1/service.yaml"
      }
      svc checkout payments
      svc ledger finance
      svc search discovery
      svc notifications

      cat > /obs/services/OWNERS.csv <<'CSV'
      service,team,updated
      checkout,payments,2025-03-02
      ledger,payments,2025-03-02
      search,discovery,2025-03-02
      CSV

      cat > /obs/platform/teams.yml <<'YML'
      # Every team that can own a service, and where its pages go.
      teams:
        payments: http://sink:8080/payments
        finance: http://sink:8080/finance
        discovery: http://sink:8080/discovery
      YML

      cat > /obs/platform/pipeline <<'SH'
      #!/usr/bin/env bash
      # pipeline SERVICE — what CI runs before a service ships.
      set -euo pipefail
      svc=${1:?usage: pipeline SERVICE}
      meta=/obs/services/$svc/service.yaml
      [ -f "$meta" ] || { echo "pipeline: $svc has no service.yaml"; exit 1; }
      python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$meta" || { echo "pipeline: $meta is not YAML"; exit 1; }
      echo "lint: ok"
      echo "test: ok"
      echo "pipeline: shipped $svc"
      SH
      chmod +x /obs/platform/pipeline

      cat >> /obs/prometheus/prometheus.yml <<'YML'

        - job_name: platform
          static_configs:
            - targets: ["gateway-exporter:9101"]
      YML

      cat > /obs/prometheus/rules/services.yml <<'YML'
      groups:
        - name: services
          rules:
            - alert: ServiceErrorRate
              expr: |
                sum by (service) (rate(http_requests_total{job="platform",code="500"}[30s]))
                  / sum by (service) (rate(http_requests_total{job="platform"}[30s])) > 0.05
              for: 10s
              labels:
                severity: page
              annotations:
                summary: "{{ $labels.service }}: more than 5% of requests are failing"
      YML

      cat > /obs/alertmanager/alertmanager.yml <<'YML'
      # Every page goes to the platform team, who look up the owner and forward it.
      route:
        receiver: platform
        group_by: [alertname, service]
        group_wait: 2s
        group_interval: 5s
        repeat_interval: 1h

      receivers:
        - name: platform
          webhook_configs:
            - url: http://sink:8080/platform
        - name: payments
          webhook_configs:
            - url: http://sink:8080/payments
        - name: finance
          webhook_configs:
            - url: http://sink:8080/finance
        - name: discovery
          webhook_configs:
            - url: http://sink:8080/discovery
      YML
      chmod -R a+rwX /obs/services /obs/platform
      chmod -R a+rX /obs/prometheus /obs/alertmanager /obs/apps
      obs-reload >/dev/null
      . /usr/local/lib/obs.sh
      prom_wait 'service_info{job="platform"}' 60 || { echo "the simulator never came up; see /obs/logs/gateway-exporter.log"; exit 1; }
      sink_reset
      echo "scenario ready: services in /obs/services, the pipeline is /obs/platform/pipeline,"
      echo "alert rules in /obs/prometheus/rules/services.yml, routing in /obs/alertmanager/alertmanager.yml."
      echo "  promq 'service_info'"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 600
    run: |
      . /usr/local/lib/obs.sh
      probe=/obs/services/probe-unowned
      cleanup() {
        rm -f /obs/run/sim-*.fault
        rm -rf "$probe"
        [ -e /tmp/search.yaml ] && cp /tmp/search.yaml /obs/services/search/service.yaml && rm -f /tmp/search.yaml
        true
      }
      trap cleanup EXIT
      cleanup

      if [ "$(sha256sum /obs/apps/gateway_exporter.py 2>/dev/null | cut -c1-64)" != "3ea397482aa41c75b17af9236590849cd527be588ce92c60791e3f7801f8f051" ]; then
        echo "not yet: /obs/apps/gateway_exporter.py is not the simulator this lesson started. It is the"
        echo "         model the check measures against; reset the lesson to get it back."
        exit 1
      fi
      for s in checkout:payments ledger:finance search:discovery; do
        got=$(sed -n 's/^owner:[[:space:]]*//p' "/obs/services/${s%%:*}/service.yaml" 2>/dev/null | tr -d '"'"'"' ' || true)
        if [ "$got" != "${s#*:}" ]; then
          echo "not yet: /obs/services/${s%%:*}/service.yaml says owner '${got}'; it started as ${s#*:}."
          echo "         The metadata is the source of truth here; route from it rather than changing it."
          exit 1
        fi
      done
      obs_require_loaded || exit 1
      prom_wait 'service_info{job="platform"}' 30 || { echo "not yet: Prometheus has no service_info from the simulator."; exit 1; }
      # Alertmanager does not announce an alert again while an earlier firing of it is
      # still active, so a page from a previous check has to resolve first.
      for _ in $(seq 1 120); do
        [ "$(curl -s --max-time 10 "$AM/api/v2/alerts?active=true" \
          | jq '[.[] | select(.labels.alertname == "ServiceErrorRate")] | length' 2>/dev/null || echo 1)" = 0 ] && break
        sleep 1
      done

      # pages SERVICE — the sink paths that received a firing page for SERVICE.
      pages() {
        sink_all | jq -r --arg s "$1" '[.[] | select(.payload.status == "firing")
          | select(any(.payload.alerts[]; .labels.service == $s and .status == "firing")) | .path] | unique | join(" ")' 2>/dev/null || true
      }
      # expect SERVICE TEAM WHY — fault the service, wait for its page, require it at TEAM only.
      fault_and_wait() {
        local i
        sink_reset
        for s in "$@"; do touch "/obs/run/sim-${s%%:*}.fault"; done
        for i in $(seq 1 90); do
          local done=1
          for s in "$@"; do [ -n "$(pages "${s%%:*}")" ] || done=0; done
          [ "$done" = 1 ] && break
          sleep 1
        done
        sleep 4
        rm -f /obs/run/sim-*.fault
      }
      expect() {  # expect SERVICE TEAM
        local got
        got=$(pages "$1")
        if [ "$got" != "/$2" ]; then
          echo "not yet: ${1} failed, and its page went to: ${got:-nobody}. ${1}'s service.yaml says owner: $2,"
          echo "         so the page belongs at the $2 receiver, and only there."
          return 1
        fi
      }

      # 1. Each service's page reaches its owner.
      fault_and_wait checkout ledger
      expect checkout payments || exit 1
      expect ledger finance || {
        echo "         OWNERS.csv says payments for ledger; it was last updated in March 2025."
        exit 1; }

      # 2. The owner changes in the metadata, and the next page follows it, with no other edit.
      cp /obs/services/search/service.yaml /tmp/search.yaml
      sed -i 's/^owner:.*/owner: payments/' /obs/services/search/service.yaml
      sleep 12
      fault_and_wait search
      if ! expect search payments; then
        echo "         The check moved search to payments in search's own service.yaml and changed nothing"
        echo "         else. Routing that does not follow is a copy of the metadata, not the metadata."
        exit 1
      fi
      cleanup

      # 3. The pipeline refuses a service nobody owns.
      rc=0; out=$(/obs/platform/pipeline notifications 2>&1) || rc=$?
      if [ "$rc" = 0 ]; then
        echo "not yet: /obs/platform/pipeline notifications ships it, and notifications has no owner."
        echo "         Its first page would go to whoever answers the platform pager."
        exit 1
      fi
      mkdir -p "$probe"
      printf 'name: probe-unowned\nowner: nobody-in-particular\ntier: 2\n' > "$probe/service.yaml"
      rc=0; out=$(/obs/platform/pipeline probe-unowned 2>&1) || rc=$?
      if [ "$rc" = 0 ]; then
        echo "not yet: the pipeline ships a service whose owner is 'nobody-in-particular', which is not a"
        echo "         team in /obs/platform/teams.yml. An owner with no pager is no owner."
        exit 1
      fi
      printf 'name: probe-unowned\nowner: finance\ntier: 2\n' > "$probe/service.yaml"
      rc=0; out=$(/obs/platform/pipeline probe-unowned 2>&1) || rc=$?
      if [ "$rc" != 0 ]; then
        echo "not yet: the pipeline refuses a service owned by finance, a real team. Its output:"
        printf '%s\n' "$out" | tail -3 | sed 's/^/         /'
        exit 1
      fi

      echo "PASS — pages reach payments and finance from service.yaml, follow an owner change with no other edit, and the pipeline stops an unowned service."
