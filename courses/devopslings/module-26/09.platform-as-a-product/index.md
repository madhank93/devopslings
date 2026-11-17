---
kind: lesson
title: "A roadmap from the data, not from the loudest request"
description: |
  Planning is next week. The platform's request board has a clear winner,
  migrate everything to Kubernetes, with forty-one votes. The platform also
  has a quarter of adoption, toil and SLO data that nobody has looked at
  together. Write the roadmap from the data, with a measurable success
  criterion for every item, and say what you will not do.
name: platform-as-a-product
slug: platform-as-a-product
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
      """platform-sim: the platform's quarter, as three sets of numbers, on :9101.

      A model, not a platform: what the platform team would have if adoption,
      toil and the platform SLO had been measured all quarter.
      """
      import random
      import time

      from prometheus_client import Gauge, start_http_server

      share = Gauge("platform_golden_path_share", "Share of a team's builds on the golden path, last 28 days.", ["team"])
      toil = Gauge("platform_toil_hours_weekly", "Platform engineer hours per week on manual work, by category, last quarter.", ["category"])
      bad = Gauge("platform_journey_bad_ratio", "Share of changes that missed the 30-minute objective, by the step that made them miss it, last 28 days.", ["step"])
      sli = Gauge("platform_journey_sli_ratio", "Share of changes that reached production within 30 minutes, last 28 days.")

      SHARE = {"web": 0.96, "api": 0.91, "payments": 0.88, "search": 0.62, "data": 0.04, "mobile": 0.07}
      TOIL = {"secret-rotation": 21, "access-requests": 6, "onboarding": 5, "runner-restarts": 4,
              "env-cleanup": 3, "dns-changes": 2}
      BAD = {"queue": 0.034, "deploy": 0.011, "build": 0.004, "push": 0.002}

      start_http_server(9101)
      while True:
          for k, v in SHARE.items():
              share.labels(k).set(round(v + random.uniform(-0.002, 0.002), 4))
          for k, v in TOIL.items():
              toil.labels(k).set(v)
          for k, v in BAD.items():
              bad.labels(k).set(v)
          sli.set(round(1 - sum(BAD.values()), 4))
          time.sleep(5)
      PY

      cat > /obs/platform/requests.md <<'MD'
      # Platform request board, top requests by votes

      | votes | request | from |
      |---:|---|---|
      | 41 | Migrate everything to Kubernetes | many teams |
      | 33 | Dark mode for the developer portal | many teams |
      | 29 | A self-hosted LLM that reviews every pull request | api, web |
      | 5 | Faster CI for the data team | data |
      | 3 | Stop rotating secrets by hand | platform |
      MD

      cat > /obs/platform/ROADMAP-FORMAT.md <<'MD'
      # Roadmap format (/obs/answers/roadmap.txt)

      One line per item the platform will do next quarter:

          item: <what> | source: <adoption, toil or slo> | metric: <PromQL> | target: <op> <number>

      `metric` is the query that measures the item today and at the end of the
      quarter; `target` is where it has to be for the item to count as done, for
      example `target: < 5`. Fields are separated by ` | `, a bar with a space
      either side. One line per thing the platform will not do:

          no: <request> | <why not>
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
      prom_wait 'platform_toil_hours_weekly{job="platform"}' 60 || { echo "the simulator never came up; see /obs/logs/gateway-exporter.log"; exit 1; }
      echo "scenario ready: the request board is /obs/platform/requests.md, the format /obs/platform/ROADMAP-FORMAT.md."
      echo "The data:  curl -s gateway-exporter:9101/metrics | grep '^platform_'"
      echo "Write the roadmap to /obs/answers/roadmap.txt."

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 120
    run: |
      . /usr/local/lib/obs.sh
      a=/obs/answers/roadmap.txt

      if [ "$(sha256sum /obs/apps/gateway_exporter.py 2>/dev/null | cut -c1-64)" != "36aea4f9f5a622c7ee50a9e7a214d2ac30a1693392bb5c89ae439c41927c537d" ]; then
        echo "not yet: /obs/apps/gateway_exporter.py is not the simulator this lesson started. It is the"
        echo "         model the check measures against; reset the lesson to get it back."
        exit 1
      fi
      prom_wait 'platform_toil_hours_weekly{job="platform"}' 30 || { echo "not yet: Prometheus has no platform data from the simulator."; exit 1; }
      if [ ! -s "$a" ]; then
        echo "not yet: $a is missing. See /obs/platform/ROADMAP-FORMAT.md."
        exit 1
      fi

      field() { awk -v k="$2" -F'[[:space:]]+[|][[:space:]]+' '{ for (i = 1; i <= NF; i++) { f = $i; sub(/^[[:space:]]+/, "", f); if (index(f, k ":") == 1) { sub(/^[^:]*:[[:space:]]*/, "", f); sub(/[[:space:]]+$/, "", f); print f; exit } } }' <<<"$1"; }
      unsupported='\b(kubernetes|k8s|dark mode|llm|ai review)\b'
      sources=" "; n=0
      while IFS= read -r line; do
        n=$((n + 1))
        what=$(field "$line" item); src=$(field "$line" source | tr '[:upper:]' '[:lower:]'); q=$(field "$line" metric); tgt=$(field "$line" target)
        if grep -Eiq "$unsupported" <<<"$what"; then
          echo "not yet: item '${what}' is a request from the board. Nothing in the adoption, toil or SLO data"
          echo "         points at it; a roadmap from votes is the one this lesson replaces."
          exit 1
        fi
        case "$src" in adoption|toil|slo) ;; *)
          echo "not yet: item '${what}' has source '${src}'. Each item comes from adoption, toil or slo data."
          exit 1 ;;
        esac
        if [ -z "$q" ] || [ -n "$(prom_error "$q")" ]; then
          echo "not yet: item '${what}' has metric '${q}', which Prometheus $( [ -z "$q" ] && echo 'cannot run: it is empty' || echo "rejects: $(prom_error "$q")")."
          exit 1
        fi
        v=$(prom_val "$q")
        if [ -z "$v" ]; then
          echo "not yet: item '${what}': its metric returns nothing today, so there is no baseline to improve on."
          exit 1
        fi
        re='^(<|<=|>|>=)[[:space:]]*[0-9]+(\.[0-9]+)?$'
        if ! [[ $tgt =~ $re ]]; then
          echo "not yet: item '${what}' has target '${tgt}'. A success criterion is a comparison and a number, like '< 5'."
          exit 1
        fi
        op=$(sed -E 's/^([<>]=?).*/\1/' <<<"$tgt"); num=$(sed -E 's/^[<>]=?[[:space:]]*//' <<<"$tgt")
        if awk -v v="$v" -v n="$num" -v o="$op" 'BEGIN { exit !((o == "<" && v < n) || (o == "<=" && v <= n) || (o == ">" && v > n) || (o == ">=" && v >= n)) }'; then
          echo "not yet: item '${what}': its metric is ${v} today, which already meets '${tgt}'. A target the"
          echo "         quarter starts by meeting measures nothing the item will do."
          exit 1
        fi
        case "$src" in
          toil)
            if ! awk -v v="$v" 'BEGIN { exit !(v > 20 && v < 22) }'; then
              echo "not yet: the toil item '${what}' measures ${v} hours a week. Which category of manual work costs the"
              echo "         most? An item on a small one leaves the largest toil where it was."
              exit 1
            fi ;;
          adoption)
            if ! awk -v v="$v" 'BEGIN { exit !(v < 0.1) }'; then
              echo "not yet: the adoption item '${what}' measures ${v}. Which teams are almost entirely off the golden"
              echo "         path? Moving a team from 0.88 to 0.95 is not where the adoption gap is."
              exit 1
            fi ;;
          slo)
            if ! awk -v v="$v" 'BEGIN { exit !((v > 0.031 && v < 0.037) || (v > 0.048 && v < 0.054) || (v > 0.946 && v < 0.952)) }'; then
              echo "not yet: the SLO item '${what}' measures ${v}. Which step makes the most changes miss the objective?"
              exit 1
            fi ;;
        esac
        sources="$sources$src "
      done < <(grep -E '^[[:space:]]*item[[:space:]]*:' "$a")
      if [ "$n" -lt 3 ]; then
        echo "not yet: the roadmap has ${n} item line(s); it needs at least three, from adoption, toil and slo."
        exit 1
      fi
      for s in adoption toil slo; do
        case "$sources" in *" $s "*) ;; *)
          echo "not yet: no item comes from the ${s} data. The roadmap is derived from all three."
          exit 1 ;;
        esac
      done

      nos=0
      while IFS= read -r line; do
        what=$(sed -E 's/^[[:space:]]*no[[:space:]]*:[[:space:]]*//; s/[[:space:]]+[|][[:space:]].*//' <<<"$line")
        why=$(sed -nE 's/^[^|]*[[:space:]][|][[:space:]]+//p' <<<"$line")
        if grep -Eiq "$unsupported" <<<"$what"; then
          if [ "$(wc -w <<<"$why")" -lt 6 ]; then
            echo "not yet: no: '${what}' has no reason after a '|'. The reason is what you say to the 41 people who voted."
            exit 1
          fi
          nos=$((nos + 1))
        fi
      done < <(grep -E '^[[:space:]]*no[[:space:]]*:' "$a")
      if [ "$nos" = 0 ]; then
        echo "not yet: no 'no:' line turns down a request from the board. A roadmap that does not say what it"
        echo "         will not do gets the most-voted request added back by whoever asks loudest."
        exit 1
      fi

      echo "PASS — ${n} items from adoption, toil and SLO data, each with a target today's number does not meet, and ${nos} request(s) turned down with a reason."
