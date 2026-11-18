---
kind: lesson
title: "A load test that has never failed a build"
description: |
  cart's pipeline runs a load test before every promote, and the test has
  passed every time, including the time it promoted a build that failed one
  request in fifty. The test measures. Nothing reads what it measures. Make
  the numbers stop the pipeline.
name: k6-thresholds-as-a-gate
slug: k6-thresholds-as-a-gate
createdAt: "2026-11-16"
timingSensitive: true

sandbox:
  stack: chaos-stack
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-20/*.k6-thresholds-as-a-gate
      lesson=$1
      mkdir -p answers
      rm -f answers/promoted answers/load-test.log
      cp "$lesson/files/load.js" answers/load.js
      cp "$lesson/files/pipeline.sh" answers/pipeline.sh
      bash "$lesson/files/deploy.sh" regressed >/dev/null 2>&1 || true

      echo "scenario ready — staging (checkout:8210) is running the build that went out last week."
      echo
      echo "  answers/pipeline.sh   the pipeline's last two stages: load test, then promote"
      echo "  answers/load.js       the load test it runs"
      echo
      echo "Run the pipeline from sandboxes/chaos-stack:  bash answers/pipeline.sh"
      echo "Put a build on staging yourself with:"
      echo "  bash $lesson/files/deploy.sh healthy      (or regressed)"

  verify_done:
    timeout_seconds: 300
    run: |
      set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-20/*.k6-thresholds-as-a-gate
      lesson=$1
      for f in load.js pipeline.sh; do
        [ -s "answers/$f" ] || { echo "not yet: answers/$f is missing — rerun the lesson's init to get it back."; exit 1; }
      done

      # Stats of one run of answers/load.js against what is on staging now.
      measure() {
        docker compose exec -T k6 sh -c 'cat > /tmp/s.js && k6 run --quiet --summary-export=/tmp/s.json \
          --summary-trend-stats="p(50),p(95),p(99)" /tmp/s.js >/dev/null 2>&1; echo "rc=$?"; cat /tmp/s.json' \
          < answers/load.js 2>/dev/null || true
      }
      stats() {
        local rc p95 err
        rc=$(head -1 <<<"$1" | cut -d= -f2)
        p95=$(tail -n +2 <<<"$1" | jq -r '.metrics.http_req_duration["p(95)"] // 0 | round' 2>/dev/null || echo "?")
        err=$(tail -n +2 <<<"$1" | jq -r '(.metrics.http_req_failed.value // 0) * 100 | . * 10 | round / 10' 2>/dev/null || echo "?")
        echo "k6 exited $rc; p95 ${p95}ms, ${err}% of requests failed"
      }
      thresholds=$(docker compose exec -T k6 sh -c 'cat > /tmp/s.js && k6 inspect /tmp/s.js' < answers/load.js 2>/dev/null |
        jq -r '.thresholds // {} | to_entries | map("\(.key): \(.value | map(if type == "object" then .threshold else . end) | join(", "))") | join("; ")' 2>/dev/null || true)

      pipeline() {
        rm -f answers/promoted
        rc=0
        bash answers/pipeline.sh >/dev/null 2>&1 || rc=$?
        promoted=no; [ -e answers/promoted ] && promoted=yes
        return 0
      }

      bash "$lesson/files/deploy.sh" regressed >/dev/null 2>&1 || { echo "not yet: staging did not start — rerun the lesson's init."; exit 1; }
      pipeline
      echo "regressed build on staging: pipeline exited $rc, promoted: $promoted"
      if [ "$promoted" = no ] && [ "$rc" = 0 ]; then
        echo "not yet: the pipeline held the regressed build back, but exited 0. CI reads the exit"
        echo "status, not the output: this run shows green, nobody looks, and the build sits unpromoted"
        echo "with no failure to say why. A stage that stops the pipeline has to exit non-zero."
        exit 1
      fi
      if [ "$promoted" = yes ]; then
        m=$(measure); s=$(stats "$m"); k6rc=$(head -1 <<<"$m" | cut -d= -f2)
        echo "  answers/load.js on its own: $s"
        if [ "$k6rc" != 0 ] && [ "$k6rc" != "" ]; then
          echo "not yet: k6 failed the regressed build (exit $k6rc), and the pipeline went on anyway."
          echo "A shell runs the next command whatever the last one returned unless it is told to stop,"
          echo "and a pipeline's status is its LAST command's: \`k6 run ... | tee log\` returns tee's 0."
          echo "The exit code has to reach the shell, and the shell has to act on it."
        elif [ -z "$thresholds" ]; then
          echo "not yet: answers/load.js has no thresholds, so k6 exits 0 whatever it measures. The"
          echo "summary is for people; the exit code is for the pipeline, and without thresholds it says"
          echo "nothing. Add thresholds that this build breaks."
        else
          echo "not yet: k6 passed the regressed build. Your thresholds — $thresholds — all held."
          echo "Compare them with what this build actually does above: a threshold the bad build meets"
          echo "does not gate anything."
        fi
        exit 1
      fi

      bash "$lesson/files/deploy.sh" healthy >/dev/null 2>&1 || { echo "not yet: staging did not start — rerun the lesson's init."; exit 1; }
      pipeline
      echo "healthy build on staging: pipeline exited $rc, promoted: $promoted"
      if [ "$promoted" = no ] || [ "$rc" != 0 ]; then
        m=$(measure)
        echo "  answers/load.js on its own: $(stats "$m")"
        if [ "$(head -1 <<<"$m" | cut -d= -f2)" != 0 ]; then
          echo "not yet: the pipeline stopped the healthy build too. Thresholds — $thresholds — that a good"
          echo "build cannot meet are a gate that is always shut, and the team learns to bypass it."
          echo "Set them where the healthy build passes with room to spare and the regressed one does not."
        else
          echo "not yet: k6 passed the healthy build, but the pipeline did not promote it (exit $rc)."
          echo "Run bash answers/pipeline.sh with the healthy build on staging and read what stops it."
        fi
        exit 1
      fi
      echo "PASS — the regressed build stopped the pipeline at the load test; the healthy build was promoted."
---
