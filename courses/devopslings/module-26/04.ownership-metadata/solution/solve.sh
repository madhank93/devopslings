#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The alert joins service_info to take the owner's team label; Alertmanager
# routes on team; the pipeline refuses a service whose owner is not a team.
set -euo pipefail

cat > /obs/prometheus/rules/services.yml <<'YML'
groups:
  - name: services
    rules:
      - alert: ServiceErrorRate
        # The ratio, with the owning team copied from the service's own metadata.
        expr: |
          (
            sum by (service) (rate(http_requests_total{job="platform",code="500"}[30s]))
              / sum by (service) (rate(http_requests_total{job="platform"}[30s])) > 0.05
          )
          * on (service) group_left (team) max by (service, team) (service_info{job="platform"})
        for: 10s
        labels:
          severity: page
        annotations:
          summary: "{{ $labels.service }}: more than 5% of requests are failing"
YML

cat > /obs/alertmanager/alertmanager.yml <<'YML'
# Pages go to the team the alert's team label names; no team, and the
# platform pager gets it.
route:
  receiver: platform
  group_by: [alertname, service]
  group_wait: 2s
  group_interval: 5s
  repeat_interval: 1h
  routes:
    - matchers: ['team="payments"']
      receiver: payments
    - matchers: ['team="finance"']
      receiver: finance
    - matchers: ['team="discovery"']
      receiver: discovery

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

cat > /obs/platform/pipeline <<'SH'
#!/usr/bin/env bash
# pipeline SERVICE — what CI runs before a service ships.
set -euo pipefail
svc=${1:?usage: pipeline SERVICE}
meta=/obs/services/$svc/service.yaml
[ -f "$meta" ] || { echo "pipeline: $svc has no service.yaml"; exit 1; }
python3 - "$meta" <<'PY' || exit 1
import sys, yaml
meta = yaml.safe_load(open(sys.argv[1])) or {}
teams = (yaml.safe_load(open("/obs/platform/teams.yml")) or {}).get("teams", {})
owner = meta.get("owner")
if not owner:
    sys.exit(f"pipeline: {sys.argv[1]} has no owner; a service ships with a team that gets its pages")
if owner not in teams:
    sys.exit(f"pipeline: owner '{owner}' is not a team in /obs/platform/teams.yml")
PY
echo "lint: ok"
echo "test: ok"
echo "pipeline: shipped $svc"
SH

obs-reload
