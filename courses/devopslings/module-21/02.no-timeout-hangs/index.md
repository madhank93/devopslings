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
      env_val() { grep -E "^$1=" .env 2>/dev/null | cut -d= -f2- | tr -d '"' || true; }
      ctr_val() { docker compose exec -T checkout printenv "$1" 2>/dev/null | tr -d '\r' || true; }
      want_conn=$(env_val PRICING_CONNECT_TIMEOUT); got_conn=$(ctr_val PRICING_CONNECT_TIMEOUT)
      want_read=$(env_val PRICING_READ_TIMEOUT);    got_read=$(ctr_val PRICING_READ_TIMEOUT)
      want_fb=$(env_val PRICING_FALLBACK);          got_fb=$(ctr_val PRICING_FALLBACK)

      if [ "${want_conn:-0}" != "${got_conn:-0}" ] || [ "${want_read:-0}" != "${got_read:-0}" ] \
         || [ "${want_fb:-}" != "${got_fb:-}" ]; then
        echo "not yet: your .env is not what the running container has."
        echo "  .env says      CONNECT_TIMEOUT='${want_conn:-}' READ_TIMEOUT='${want_read:-}' FALLBACK='${want_fb:-}'"
        echo "  container has  CONNECT_TIMEOUT='${got_conn:-}' READ_TIMEOUT='${got_read:-}' FALLBACK='${got_fb:-}'"
        echo
        echo "compose reads .env when it creates a container, not while one runs."
        echo "Apply it:  docker compose up -d"
        exit 1
      fi

      # k6's thresholds are the grade. It exits non-zero when p(95) or the
      # check rate is breached, so this is the whole assertion.
      if out=$(docker compose exec -T k6 k6 run --quiet /scripts/checkout.js 2>&1); then
        printf '%s\n' "$out" | grep -E 'p\(95\)|checks' | head -4 || true
        echo
        echo "PASS — checkout kept answering while pricing was 8s slow."
        curl -fsS -X DELETE http://127.0.0.1:8474/proxies/pricing/toxics/latency \
          >/dev/null 2>&1 || true
        exit 0
      fi

      # On failure the latency stays injected, so the student can curl
      # /checkout and see the slow path the grader saw.
      printf '%s\n' "$out" | grep -E 'p\(95\)|checks|✗|thresholds' | head -12 || true
      echo
      sample=$(curl -s --max-time 15 -w ' HTTP %{http_code} in %{time_total}s' \
                 http://127.0.0.1:18090/checkout 2>/dev/null || true)

      # The wait checkout will actually apply, mirroring app/checkout.py: a
      # read timeout of 0 falls back to 3s when only a connect timeout is set.
      read_s=$(awk -v c="${got_conn:-0}" -v r="${got_read:-0}" 'BEGIN {
        if (c + 0 <= 0 && r + 0 <= 0) print "none"; else if (r + 0 > 0) print r + 0; else print 3 }')

      if [ "$read_s" = "none" ]; then
        echo "not yet: checkout waited out the full 8s on pricing — it has no read"
        echo "timeout (PRICING_READ_TIMEOUT='${got_read:-}'), so a slow answer is waited for"
        echo "indefinitely. One request under the fault: ${sample:-no answer}"
      elif awk -v r="$read_s" 'BEGIN { exit !(r >= 3) }'; then
        echo "not yet: checkout gives up on pricing after ${read_s}s (PRICING_READ_TIMEOUT='${got_read:-}',"
        echo "CONNECT='${got_conn:-}'), and the latency budget is p(95) < 3s — a request that"
        echo "waits out the whole timeout has already missed it."
        echo "One request under the fault: ${sample:-no answer}"
      elif [ -z "${got_fb:-}" ]; then
        echo "not yet: checkout now gives up after ${read_s}s, and then answers with an error"
        echo "rather than a price (PRICING_FALLBACK is empty). One request under the fault:"
        echo "  ${sample:-no answer}"
      else
        echo "not yet: the load test failed its thresholds with a ${read_s}s read timeout and"
        echo "fallback '${got_fb}'. One request under the fault:"
        echo "  ${sample:-no answer}"
      fi
      exit 1
---
