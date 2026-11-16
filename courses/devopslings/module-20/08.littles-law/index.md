---
kind: lesson
title: "How many workers month-end needs"
description: |
  The invoice renderer falls over every month-end, and every month someone
  doubles its workers and hopes. The number it needs is one multiplication
  away: arrivals per second times seconds per render. Work it out, then prove
  it with a run.
name: littles-law
slug: littles-law
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
      set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-20/*.littles-law
      lesson=$1
      # .env lives outside any container, so a solved attempt would otherwise stay solved.
      echo "WORKERS=8" > .env
      mkdir -p answers
      rm -f answers/littles-law.txt
      cp "$lesson/files/peak.js" answers/peak.js
      bash "$lesson/files/deploy.sh" >/dev/null 2>&1 || true

      echo "scenario ready — render is on checkout:8240 with WORKERS=8 (sandboxes/chaos-stack/.env)."
      echo
      echo "Month-end is 150 invoices a second. Replay it with:"
      echo "  docker compose exec -T k6 k6 run - < answers/peak.js"
      echo "Apply a new WORKERS with:  bash $lesson/files/deploy.sh"

  verify_done:
    timeout_seconds: 300
    run: |
      set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-20/*.littles-law
      lesson=$1
      ans=answers/littles-law.txt
      field() { grep -E "^$1=" "$ans" 2>/dev/null | tail -1 | cut -d= -f2- | tr -dc '0-9.' || true; }
      w=$(field service_time_ms); l=$(field workers_needed)
      workers=$(grep -E '^WORKERS=' .env 2>/dev/null | tail -1 | cut -d= -f2- | tr -dc '0-9' || true)
      if [ -z "$w" ] || [ -z "$l" ]; then
        echo "not yet: $ans needs service_time_ms=<n> and workers_needed=<n>, one per line."
        exit 1
      fi
      if awk -v w="$w" 'BEGIN { exit !(w < 170 || w > 260) }'; then
        echo "not yet: service_time_ms=$w. Time one render with the service idle — a single request,"
        echo "or a test at a rate the workers can easily keep up with — so no time is spent queueing."
        exit 1
      fi
      if awk -v l="$l" -v w="$w" 'BEGIN { x = 150 * w / 1000; exit !(l < 0.9 * x || l > 1.1 * x) }'; then
        echo "not yet: workers_needed=$l, but 150 renders a second at ${w}ms each keeps"
        echo "$(awk -v w="$w" 'BEGIN { printf "%.0f", 150 * w / 1000 }') renders in progress on average (L = λW: arrivals per second times seconds each)."
        exit 1
      fi
      if [ -z "$workers" ]; then
        echo "not yet: sandboxes/chaos-stack/.env needs WORKERS=<n>."
        exit 1
      fi
      if [ "$workers" -gt "$(awk -v l="$l" 'BEGIN { printf "%d", 1.5 * l }')" ]; then
        echo "not yet: WORKERS=$workers is more than half as many again as the $l your own arithmetic"
        echo "says are busy at the peak. That is the doubling-and-hoping this lesson replaces: size"
        echo "from the number, with headroom, not from a guess. Set WORKERS from workers_needed."
        exit 1
      fi
      bash "$lesson/files/deploy.sh" >/dev/null 2>&1 || {
        echo "not yet: render did not start with WORKERS=$workers:"
        docker compose exec -T checkout tail -3 /srv/littles-law/render.log 2>/dev/null || true
        exit 1
      }
      sj=$(docker compose exec -T k6 sh -c 'cat > /tmp/s.js && k6 run --quiet --summary-export=/tmp/s.json /tmp/s.js >/dev/null 2>&1; cat /tmp/s.json' \
        < "$lesson/files/peak.js" 2>/dev/null || true)
      p99=$(jq -r '.metrics.http_req_duration["p(99)"] // empty | round' <<<"$sj" 2>/dev/null || true)
      rate=$(jq -r '.metrics.http_reqs.rate // 0 | round' <<<"$sj" 2>/dev/null || echo 0)
      failed=$(jq -r '(.metrics.http_req_failed.value // 1) * 100 | round' <<<"$sj" 2>/dev/null || echo 100)
      if [ -z "$p99" ]; then
        echo "not yet: the month-end run did not finish. Run answers/peak.js yourself and read what k6 says."
        exit 1
      fi
      echo "this check measured, with WORKERS=$workers: p99 ${p99}ms at $rate renders a second, ${failed}% failed"
      if [ "$p99" -ge 400 ] || [ "$failed" -gt 0 ]; then
        if [ "$workers" -lt "$(awk -v l="$l" 'BEGIN { printf "%d", l }')" ]; then
          echo "not yet: $workers workers finish at most $workers / ${w}ms = $(awk -v n="$workers" -v w="$w" 'BEGIN { printf "%.0f", n * 1000 / w }') renders a second, fewer than"
          echo "the 150 that arrive. The rest queue, and the queue grows for as long as the peak lasts."
        else
          echo "not yet: with WORKERS=$workers the p99 is ${p99}ms, over the 400ms budget. workers_needed is"
          echo "the AVERAGE number busy. At exactly that many every worker is busy all the time, and any"
          echo "moment of bad luck — a few slow renders together — starts a queue that never drains."
          echo "Leave headroom: run the workers at most about 80-85% busy."
        fi
        exit 1
      fi
      echo "PASS — $l renders in progress on average; $workers workers carry the peak at p99 ${p99}ms."
---
