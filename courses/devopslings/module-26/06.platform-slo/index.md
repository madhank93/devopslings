---
kind: lesson
title: "The platform is up, and nobody can ship"
description: |
  The platform's SLO dashboard says 100% this week. In the same week, half
  the engineering org missed a release because a change took an hour to
  reach production. Every component was up. Measure the thing the platform
  exists for, a developer's change reaching production, and compute the
  error budget against that.
name: platform-slo
slug: platform-slo
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
      rm -rf /obs/platform
      mkdir -p /obs/platform

      # The model. The grader refuses to run against an edited copy.
      cat > /obs/apps/gateway_exporter.py <<'PY'
      """platform-sim: the delivery platform as its metrics see it, on :9101.

      A model, not a platform. Developers' changes ("journeys") start at a
      steady rate and each one either reaches production or fails; a journey's
      duration is push to deployed. The forge, the runners, the registry and
      the deployer report healthy throughout. While /obs/run/platform.degrade
      exists, most journeys wait 40 minutes for a runner, and still deploy.
      """
      import math
      import os
      import random
      import time

      from prometheus_client import Counter, Gauge, Histogram, start_http_server

      COMPONENTS = ["forge", "runner", "registry", "deployer"]
      up = Gauge("platform_component_up", "1 while the component answers its health check.", ["component"])
      http = Counter("platform_http_requests", "Requests each component served.", ["component", "code"])
      builds = Counter("ci_builds", "Builds, by result.", ["result"])
      journeys = Counter("platform_journeys", "Changes that finished their way to production, by outcome.", ["outcome"])
      duration = Histogram("platform_journey_duration_seconds", "Push to deployed, for changes that deployed.",
                           buckets=[300, 600, 900, 1200, 1800, 2700, 3600, 5400, 7200])
      queue = Histogram("ci_queue_wait_seconds", "Time a build waited for a runner.",
                        buckets=[10, 30, 60, 300, 600, 1800, 3600])

      start_http_server(9101)
      for c in COMPONENTS:
          up.labels(c).set(1)
      while True:
          degraded = os.path.exists("/obs/run/platform.degrade")
          for c in COMPONENTS:
              http.labels(c, "200").inc(10)
          for _ in range(3):
              builds.labels("success" if random.random() > 0.01 else "failure").inc()
              if random.random() < 0.003:
                  journeys.labels("failed").inc()
                  continue
              wait = 2400 + random.uniform(-120, 120) if degraded and random.random() < 0.7 else random.uniform(5, 40)
              queue.observe(wait)
              duration.observe(wait + random.lognormvariate(math.log(540), 0.35))
              journeys.labels("deployed").inc()
          time.sleep(1)
      PY

      cat >> /obs/prometheus/prometheus.yml <<'YML'

        - job_name: platform
          static_configs:
            - targets: ["gateway-exporter:9101"]
      YML

      # What the platform reports today.
      cat > /obs/prometheus/rules/platform-slo.yml <<'YML'
      groups:
        - name: platform-slo
          rules:
            # Platform availability: every component up. SLO 99.9%.
            - record: platform:availability:ratio
              expr: avg(platform_component_up{job="platform"})
      YML

      cat > /obs/platform/SLO.md <<'MD'
      # Platform SLO

      **Objective:** 99% of changes reach production within 30 minutes of the
      push, over a rolling hour (the lab's stand-in for 28 days).

      **Status this week:** availability 100% (`platform:availability:ratio`).

      ## From the engineering all-hands

      > "Thursday a one-line fix took 55 minutes to reach production. The platform
      > dashboard was green the entire time." — release manager
      MD
      chmod -R a+rwX /obs/platform
      chmod -R a+rX /obs/prometheus /obs/apps
      obs-reload >/dev/null
      . /usr/local/lib/obs.sh
      prom_wait 'platform_journeys_total{job="platform"}' 60 || { echo "the simulator never came up; see /obs/logs/gateway-exporter.log"; exit 1; }
      echo "scenario ready: the SLO is in /obs/platform/SLO.md, the rules in /obs/prometheus/rules/platform-slo.yml."
      echo "  promq 'platform:availability:ratio'"
      echo "  curl -s gateway-exporter:9101/metrics | grep -v '^#'"
      echo "To see what the simulator models as a bad day: touch /obs/run/platform.degrade (rm it to stop)."

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 600
    run: |
      . /usr/local/lib/obs.sh
      trap 'rm -f /obs/run/platform.degrade' EXIT
      rm -f /obs/run/platform.degrade

      if [ "$(sha256sum /obs/apps/gateway_exporter.py 2>/dev/null | cut -c1-64)" != "26ef196238aa2586f21b2e34a37960cb6171b2806f0f388b13ee61e880437ed4" ]; then
        echo "not yet: /obs/apps/gateway_exporter.py is not the simulator this lesson started. It is the"
        echo "         model the check measures against; reset the lesson to get it back."
        exit 1
      fi
      obs_require_loaded || exit 1

      SLI='platform_journey:sli:ratio_1m'
      BUDGET='platform_journey:error_budget_remaining:1h'
      # The grader's own reading of the objective: deployed within 1800s, out of every journey.
      good='sum(rate(platform_journey_duration_seconds_bucket{job="platform",le="1800.0"}[1m])) / sum(rate(platform_journeys_total{job="platform"}[1m]))'
      for r in "$SLI" "$BUDGET"; do
        # A rule loaded moments ago has not been evaluated yet.
        prom_wait "$r" 60 || true
        if [ "$(prom_count "$r")" = 0 ]; then
          echo "not yet: Prometheus has no series called $r. Record it in a rule file under"
          echo "         /obs/prometheus/rules/ and run obs-reload. If the rule is there, its expression"
          echo "         returns nothing: run it in promq (the simulator writes histogram bounds as le=\"1800.0\")."
          exit 1
        fi
        if [ "$(prom_count "$r")" -gt 1 ]; then
          echo "not yet: $r has $(prom_count "$r") series. It is one number for the platform; aggregate it."
          exit 1
        fi
      done

      # 1. A normal minute: the SLI says the journey is fine.
      for _ in $(seq 1 90); do
        v=$(prom_val "$good"); awk -v v="${v:-0}" 'BEGIN { exit !(v >= 0.97) }' && break
        sleep 2
      done
      sleep 6
      ok=$(prom_val "$SLI")
      if ! awk -v v="${ok:-x}" 'BEGIN { exit !(v ~ /^[0-9.e+-]+$/ && v >= 0.95 && v <= 1.0001) }'; then
        echo "not yet: with every change reaching production in about ten minutes, $SLI is ${ok:-empty}."
        echo "         It is the fraction of journeys that were good: near 1 on a normal minute."
        exit 1
      fi

      # 2. The bad day: every component healthy, changes deploy, an hour late.
      touch /obs/run/platform.degrade
      sleep 45
      comp=$(prom_val 'min(platform_component_up{job="platform"})')
      cerr=$(prom_val 'sum(rate(platform_http_requests_total{job="platform",code!~"2.."}[1m])) or vector(0)')
      bad=$(prom_val "$SLI")
      if ! awk -v v="${bad:-1}" 'BEGIN { exit !(v < 0.9) }'; then
        echo "not yet: in the seeded degradation, $SLI is still ${bad:-empty}, while 70% of changes take"
        echo "         about 50 minutes to reach production against an objective of 30."
        near() { awk -v a="${bad:-0}" -v b="${1:-9}" 'BEGIN { d = a - b; exit !(d < 0.02 && d > -0.02) }'; }
        if near "$(prom_val 'avg(platform_component_up{job="platform"})')"; then
          echo "         It matches component uptime (min ${comp}, http errors ${cerr}/s): every component is"
          echo "         healthy. The developer's journey is not."
        elif near "$(prom_val 'sum(rate(platform_journeys_total{job="platform",outcome="deployed"}[1m])) / sum(rate(platform_journeys_total{job="platform"}[1m]))')"; then
          echo "         It matches the share of changes that deployed. They all still deploy; they are late."
        elif near "$(prom_val 'sum(rate(ci_builds_total{job="platform",result="success"}[1m])) / sum(rate(ci_builds_total{job="platform"}[1m]))')"; then
          echo "         It matches the build success rate. The builds pass; they wait 40 minutes to start."
        elif near "$(prom_val 'sum(rate(platform_journey_duration_seconds_bucket{job="platform",le="3600.0"}[1m])) / sum(rate(platform_journeys_total{job="platform"}[1m]))')"; then
          echo "         It matches the share deployed within an hour. The objective is 30 minutes."
        fi
        exit 1
      fi

      # 3. The budget is spent against that SLI, over the hour.
      sleep 6
      want=$(prom_val '1 - (1 - (sum(increase(platform_journey_duration_seconds_bucket{job="platform",le="1800.0"}[1h])) / sum(increase(platform_journeys_total{job="platform"}[1h])))) / (1 - 0.99)')
      got=$(prom_val "$BUDGET")
      if ! awk -v g="${got:-x}" -v w="${want:-0}" 'BEGIN { d = g - w; if (d < 0) d = -d; a = (w < 0 ? -w : w); exit !(g ~ /^[-0-9.e+]+$/ && d <= 0.1 + 0.1 * a) }'; then
        echo "not yet: $BUDGET is ${got:-empty}. Counting the good journeys over the last hour against a"
        echo "         99% objective gives ${want}: 1 is untouched, 0 is spent, below 0 is overspent."
        awk -v g="${got:-0}" 'BEGIN { exit !(g > 0.99 && g < 1.01) }' && \
          echo "         A budget that stays at 1 through this is being spent against something that stayed healthy."
        exit 1
      fi

      echo "PASS — the SLI is ${ok} on a normal minute and ${bad} with every component healthy; ${BUDGET} = ${got} (expected ${want})."
