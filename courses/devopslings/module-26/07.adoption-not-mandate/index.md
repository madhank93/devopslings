---
kind: lesson
title: "Two teams that will not take the golden path"
description: |
  Three teams build on the golden path. Data and mobile run their own
  pipelines, and leadership wants a mandate. Mobile says the approval gate is
  the problem. Find out from the pipeline data why they really route around
  it, change the path, and see them move without being told to.
name: adoption-not-mandate
slug: adoption-not-mandate
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
      """platform-sim: five teams choosing a pipeline, on :9101.

      A model of adoption, not of CI. Every second each team starts builds.
      A team runs the golden path when it is no slower for them than their own
      pipeline (within 10%), or when /obs/platform/golden-path.yml mandates it;
      otherwise it runs its own pipeline, and tries the golden path one build
      in twenty. Stage durations are what each team's builds would take, from
      the team's profile and the golden path's config, read every second.
      """
      import random
      import time

      import yaml
      from prometheus_client import Counter, Summary, start_http_server

      # Per team: dependency install uncached / cached, test suite serial, own pipeline total.
      TEAMS = {
          "web":      {"deps": 70,   "cached": 25, "test": 200, "own": 420},
          "api":      {"deps": 90,   "cached": 30, "test": 280, "own": 520},
          "payments": {"deps": 80,   "cached": 30, "test": 320, "own": 560},
          "data":     {"deps": 960,  "cached": 45, "test": 240, "own": 390},
          "mobile":   {"deps": 1140, "cached": 50, "test": 260, "own": 420},
      }
      runs = Counter("ci_pipeline_runs", "Pipeline runs started, by team and pipeline.", ["team", "pipeline"])
      stage_time = Summary("ci_pipeline_stage_duration_seconds", "Seconds spent in each stage.", ["team", "pipeline", "stage"])


      def config():
          try:
              c = yaml.safe_load(open("/obs/platform/golden-path.yml")) or {}
          except Exception:
              c = {}
          return c if isinstance(c, dict) else {}


      def golden_stages(t, c):
          st = c.get("stages") or {}
          cache = bool((st.get("deps") or {}).get("cache", False))
          parallel = max(1, int((st.get("test") or {}).get("parallel", 1) or 1))
          approval = bool((st.get("approval") or {}).get("required", True))
          return {
              "deps": t["cached"] if cache else t["deps"],
              "test": t["test"] / parallel + 15 * (parallel - 1),
              "approval": 30 if approval else 0,
              "deploy": 45,
          }


      def own_stages(t):
          rest = t["own"] - t["cached"] - t["test"]
          return {"deps": t["cached"], "test": t["test"], "deploy": rest}


      start_http_server(9101)
      while True:
          c = config()
          mandate = set(c.get("mandate") or [])
          for team, t in TEAMS.items():
              g = golden_stages(t, c)
              prefers_golden = sum(g.values()) <= t["own"] * 1.1 or team in mandate
              for _ in range(4):
                  golden = prefers_golden or random.random() < 0.05
                  name, stages = ("golden", g) if golden else ("own", own_stages(t))
                  runs.labels(team, name).inc()
                  for stage, secs in stages.items():
                      stage_time.labels(team, name, stage).observe(secs * random.uniform(0.9, 1.1))
          time.sleep(1)
      PY

      cat > /obs/platform/golden-path.yml <<'YML'
      # The golden path's pipeline, as every team gets it.
      stages:
        deps:
          cache: false        # install dependencies fresh on every build
        test:
          parallel: 1         # test shards
        approval:
          required: true      # a second engineer approves the deploy (SOC 2 control CC8.1)
      # Teams that must use the golden path, whatever it costs them.
      mandate: []
      YML

      cat > /obs/platform/FEEDBACK.md <<'MD'
      # Why teams are not on the golden path

      **mobile** (survey, Q3): "The approval gate. Waiting for someone to click
      approve kills our flow. Our own pipeline doesn't have it."

      **data** (survey, Q3): no response.

      **VP Engineering**: "Two years in, two teams still run their own CI. Add
      them to `mandate:` this sprint."
      MD

      cat >> /obs/prometheus/prometheus.yml <<'YML'

        - job_name: platform
          static_configs:
            - targets: ["gateway-exporter:9101"]
      YML
      chmod -R a+rwX /obs/platform
      chmod -R a+rX /obs/prometheus /obs/apps
      obs-reload >/dev/null
      . /usr/local/lib/obs.sh
      prom_wait 'ci_pipeline_runs_total{job="platform"}' 60 || { echo "the simulator never came up; see /obs/logs/gateway-exporter.log"; exit 1; }
      echo "scenario ready: the golden path's config is /obs/platform/golden-path.yml, what teams said is in"
      echo "/obs/platform/FEEDBACK.md. Write your finding to /obs/answers/adoption.txt."
      echo "  promq 'sum by (team, pipeline) (rate(ci_pipeline_runs_total[1m]))'"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      . /usr/local/lib/obs.sh
      a=/obs/answers/adoption.txt
      cfg=/obs/platform/golden-path.yml

      if [ "$(sha256sum /obs/apps/gateway_exporter.py 2>/dev/null | cut -c1-64)" != "62f922bcc599ccc5e76d0839a3f4dee3a45f7c7916dfae064b5660f375c29469" ]; then
        echo "not yet: /obs/apps/gateway_exporter.py is not the simulator this lesson started. It is the"
        echo "         model the check measures against; reset the lesson to get it back."
        exit 1
      fi
      obs_require_loaded || exit 1

      cfgval() { python3 -c 'import sys, yaml
      c = yaml.safe_load(open(sys.argv[1])) or {}
      v = c
      for k in sys.argv[2].split("."):
          v = v.get(k) if isinstance(v, dict) else None
      print(v)' "$cfg" "$1" 2>/dev/null || echo error; }

      m=$(cfgval mandate)
      if [ "$m" != "[]" ] && [ "$m" != None ]; then
        echo "not yet: golden-path.yml mandates ${m}. A mandated team is on the path because it was told"
        echo "         to be, and still pays whatever drove it off; adoption has to come from the path being better."
        exit 1
      fi
      if [ "$(cfgval stages.approval.required)" != True ]; then
        echo "not yet: the approval gate is off for every team. It is a SOC 2 control, and the pipeline data"
        echo "         shows it costs data and mobile 30 seconds a build. Mobile asserted it was the reason; it is not."
        exit 1
      fi

      # The answer: the cause, and the query that shows it.
      val() { sed -n "s/^[[:space:]]*$1[[:space:]]*:[[:space:]]*//p" "$a" 2>/dev/null | head -1 || true; }
      if [ ! -s "$a" ]; then
        echo "not yet: $a is missing. It needs a 'stage:' line and an 'evidence:' line."
        exit 1
      fi
      stage=$(val stage | tr '[:upper:]' '[:lower:]' | tr -d ' `"')
      case "$stage" in
        deps) ;;
        approval)
          echo "not yet: stage: approval is what mobile said. The data says approval takes 30 seconds of a"
          echo "         build for them. Compare their golden-path stage durations with their own pipeline's."
          exit 1 ;;
        test)
          echo "not yet: stage: test. Data and mobile's tests take about as long on the golden path as on their"
          echo "         own pipeline. Which stage is ten times longer for them on the golden path?"
          exit 1 ;;
        *)
          echo "not yet: stage: is '${stage:-missing}'. Name the golden-path stage (deps, test, approval or deploy)"
          echo "         that costs data and mobile the time."
          exit 1 ;;
      esac
      ev=$(val evidence)
      if ! grep -q 'ci_pipeline_stage_duration_seconds' <<<"$ev"; then
        echo "not yet: evidence: has to be the PromQL that shows the cause, from the stage-duration metrics"
        echo "         (ci_pipeline_stage_duration_seconds_sum and _count). It is '${ev:-missing}'."
        exit 1
      fi
      err=$(prom_error "$ev")
      if [ -n "$err" ]; then
        echo "not yet: Prometheus rejects the evidence query: ${err}"
        exit 1
      fi
      # rate() needs two scrapes after the series appears.
      prom_wait "$ev" 45 || true
      if [ "$(prom_count "$ev")" = 0 ]; then
        echo "not yet: the evidence query returns no series. Evidence is a query that shows the number."
        exit 1
      fi

      # The change works: data and mobile choose the golden path on their own.
      share() { prom_val "sum(rate(ci_pipeline_runs_total{job=\"platform\",team=\"$1\",pipeline=\"golden\"}[20s])) / sum(rate(ci_pipeline_runs_total{job=\"platform\",team=\"$1\"}[20s]))"; }
      for _ in $(seq 1 45); do
        d=$(share data); mb=$(share mobile)
        awk -v a="${d:-0}" -v b="${mb:-0}" 'BEGIN { exit !(a >= 0.9 && b >= 0.9) }' && break
        sleep 2
      done
      if ! awk -v a="${d:-0}" -v b="${mb:-0}" 'BEGIN { exit !(a >= 0.9 && b >= 0.9) }'; then
        printf 'not yet: data runs %.0f%% and mobile %.0f%% of their builds on the golden path. A change that\n' "$(awk -v v="${d:-0}" 'BEGIN{print v*100}')" "$(awk -v v="${mb:-0}" 'BEGIN{print v*100}')"
        echo "         removes their reason shows up as them moving, with nobody telling them to."
        exit 1
      fi
      for t in web api payments; do
        s=$(share $t)
        if ! awk -v a="${s:-0}" 'BEGIN { exit !(a >= 0.9) }'; then
          echo "not yet: ${t} now runs only $(awk -v v="${s:-0}" 'BEGIN{printf "%.0f", v*100}')% of its builds on the golden path. The change moved"
          echo "         data and mobile and cost a team that was already on it."
          exit 1
        fi
      done

      echo "PASS — stage: deps, shown by the stage durations; data and mobile now choose the golden path, no mandate, approval kept."
