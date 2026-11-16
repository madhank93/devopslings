#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
#   severity="critical" → pager   the route matched "page", a value no rule sets
#   group_by: [service]          one notification per broken service, not per alert
#   group_wait: 30s              an outage's alerts fire seconds apart; wait to batch them
#   inhibit_rules                DatabaseDown mutes shop's alerts, which it explains
set -euo pipefail
cat > /obs/alertmanager/alertmanager.yml <<'YML'
route:
  receiver: tickets
  group_by: [service]
  group_wait: 30s
  group_interval: 5s
  repeat_interval: 1h
  routes:
    - matchers: ['severity="critical"']
      receiver: pager

# shop cannot work without db, so while db is down shop's alerts say nothing new.
inhibit_rules:
  - source_matchers: ['alertname="DatabaseDown"']
    target_matchers: ['service="shop"']

receivers:
  - name: pager
    webhook_configs:
      - url: http://sink:8080/pager
  - name: tickets
    webhook_configs:
      - url: http://sink:8080/tickets
YML
obs-reload
