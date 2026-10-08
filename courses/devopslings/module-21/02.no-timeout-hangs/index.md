---
kind: lesson
title: "The request with no timeout that hangs forever"
description: |
  checkout calls pricing on every request and both are healthy. Then pricing
  gets slow — not down, slow. Without a timeout, checkout's threads fill up
  waiting and the whole service stops answering, taking down a page that did
  not need pricing at all.
name: no-timeout-hangs
slug: no-timeout-hangs
createdAt: "2026-07-31"
timingSensitive: true

sandbox:
  stack: chaos-stack
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      # Reset the student's configuration to the naive defaults.
      #
      # This matters more than it looks. .env is a file in the sandbox
      # directory, not container state, so `compose down -v` does not touch it —
      # without this, solving the lesson once would leave it permanently solved,
      # and `reset` would hand back an already-fixed scenario. Anything a lesson
      # lets the student edit outside a container has to be reset here.
      cat > .env <<'ENV'
      PRICING_CONNECT_TIMEOUT=0
      PRICING_READ_TIMEOUT=0
      PRICING_FALLBACK=
      ENV
      docker compose up -d --wait >/dev/null 2>&1 || true

      # Clear any toxic left from a previous attempt so the student always
      # starts from a genuinely healthy system.
      curl -fsS -X DELETE http://127.0.0.1:8474/proxies/pricing/toxics/latency \
        >/dev/null 2>&1 || true

      echo "scenario ready — the stack is healthy, and that is the point."
      echo
      curl -fsS --max-time 5 http://127.0.0.1:18090/checkout || true
      echo
      echo
      echo "Nothing is broken yet. At verify time, 8 seconds of latency will be"
      echo "injected between checkout and pricing, and checkout must keep"
      echo "answering. Configure it in sandboxes/chaos-stack/.env — see the task."

  # This is what makes the module possible: the fault lands after the student's
  # work and before the check. toxiproxy adds the latency to the live proxy
  # without restarting or modifying either service.
  inject_fault:
    timeout_seconds: 120
    run: |
      curl -fsS -X DELETE http://127.0.0.1:8474/proxies/pricing/toxics/latency \
        >/dev/null 2>&1 || true

      curl -fsS -X POST http://127.0.0.1:8474/proxies/pricing/toxics \
        -H 'Content-Type: application/json' \
        -d '{"name":"latency","type":"latency","stream":"downstream","attributes":{"latency":8000,"jitter":0}}' \
        >/dev/null

      echo "fault injected: pricing responses delayed by 8s"

  verify_done:
    needs: [init_scenario, inject_fault]
    timeout_seconds: 300
    run: |
      # Editing .env does not change a running container — compose only reads it
      # when creating one. Catch that here rather than letting it surface as a
      # mysterious threshold failure, because "my config had no effect" is a
      # real deployment lesson and a terrible debugging experience.
      want_read=$(grep -E '^PRICING_READ_TIMEOUT=' .env 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
      want_fb=$(grep -E '^PRICING_FALLBACK=' .env 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
      got_read=$(docker compose exec -T checkout printenv PRICING_READ_TIMEOUT 2>/dev/null | tr -d '\r' || true)
      got_fb=$(docker compose exec -T checkout printenv PRICING_FALLBACK 2>/dev/null | tr -d '\r' || true)

      if [ "${want_read:-0}" != "${got_read:-0}" ] || [ "${want_fb:-}" != "${got_fb:-}" ]; then
        echo "not yet: your .env is not what the running container has."
        echo "  .env says      READ_TIMEOUT='${want_read:-}' FALLBACK='${want_fb:-}'"
        echo "  container has  READ_TIMEOUT='${got_read:-}' FALLBACK='${got_fb:-}'"
        echo
        echo "compose reads .env when it creates a container, not while one runs."
        echo "Apply it:  docker compose up -d"
        exit 1
      fi

      # k6's thresholds are the grade. It exits non-zero when p(95) or the
      # check rate is breached, so this is the whole assertion.
      out=$(docker compose exec -T k6 k6 run --quiet /scripts/checkout.js 2>&1) || {
        echo "$out" | grep -E 'p\(95\)|checks|✗|thresholds' | head -12
        echo
        if printf '%s' "$out" | grep -q 'http_req_duration'; then
          echo "not yet: requests are still blocking on the slow dependency — checkout has no bound on how long it will wait"
        else
          echo "not yet: the load test failed its thresholds"
        fi
        exit 1
      }

      printf '%s\n' "$out" | grep -E 'p\(95\)|checks' | head -4
      echo
      echo "PASS — checkout kept answering while pricing was 8s slow."

      curl -fsS -X DELETE http://127.0.0.1:8474/proxies/pricing/toxics/latency \
        >/dev/null 2>&1 || true
---
