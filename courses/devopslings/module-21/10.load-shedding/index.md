---
kind: lesson
title: "Degrading on purpose beats collapsing by accident"
description: |
  api can serve 40 requests a second. A surge sends it 120: a steady stream of
  checkouts and a flood of recommendation-widget calls. Every request joins
  the same queue, the queue grows without end, and checkout — the route that
  makes money, and the one that would fit easily on its own — times out with
  everything else.
name: load-shedding
slug: load-shedding
createdAt: "2026-10-09"
timingSensitive: true

sandbox:
  stack: chaos-stack
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-21/*.load-shedding
      lesson=$1

      # .env is gitignored sandbox state that outlives `compose down -v`, so it
      # is rewritten here or a solved attempt would survive a reset.
      cat > .env <<'ENV'
      API_WORKERS=16
      QUEUE_TIMEOUT_MS=0
      SHED_ALL_AT=0
      SHED_LOW_AT=0
      ENV
      bash "$lesson/files/deploy.sh" >/dev/null 2>&1 || true

      echo "scenario ready — api on checkout:8100 serves /checkout and /recommendations."
      echo "It has 2 cores and each request costs 50ms of one: 40 requests a second."
      echo
      echo "At verify time a surge sends 120 a second for 20s — 15 checkouts and 105"
      echo "recommendations. Checkout has to keep working. Configure api's admission"
      echo "control in sandboxes/chaos-stack/.env — see the task."

  # The surge itself is the load test. This redeploys api from .env so every
  # verify grades the settings as written, from an empty queue. It never fails
  # on the student's settings; verify_done reports a api that did not start.
  inject_fault:
    timeout_seconds: 120
    run: |
      set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-21/*.load-shedding
      bash "$1/files/deploy.sh" >/dev/null 2>&1 || true
      echo "fault armed: 3x api's capacity arrives as soon as the load test starts"

  verify_done:
    needs: [init_scenario, inject_fault]
    timeout_seconds: 300
    run: |
      set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-21/*.load-shedding
      lesson=$1
      env_val() { grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || true; }
      workers=$(env_val API_WORKERS); qt=$(env_val QUEUE_TIMEOUT_MS)
      all=$(env_val SHED_ALL_AT); low=$(env_val SHED_LOW_AT)
      : "${workers:=16}" "${qt:=0}" "${all:=0}" "${low:=0}"

      if ! docker compose exec -T checkout python3 -c \
          "import urllib.request; urllib.request.urlopen('http://localhost:8100/health', timeout=2)" \
          >/dev/null 2>&1; then
        echo "not yet: api did not start with the settings in .env. Its log:"
        docker compose exec -T checkout tail -n 5 /srv/load-shedding/api.log 2>/dev/null || true
        exit 1
      fi

      rc=0
      out=$(docker compose exec -T k6 k6 run --quiet --log-output=none - \
            < "$lesson/files/surge.js" 2>&1) || rc=$?

      val() { printf '%s\n' "$out" | grep -E "^$1=" | head -1 | cut -d= -f2 || true; }
      ok=$(val checkout_ok); c99=$(val checkout_p99); r99=$(val recs_p99); served=$(val recs_served)
      pct=$(awk -v r="${ok:-0}" 'BEGIN { printf "%.1f%%", r * 100 }')

      if [ -z "$ok" ]; then
        printf '%s\n' "$out" | tail -15
        echo "not yet: the load test did not finish, so there is nothing to grade — output above."
        exit 1
      fi
      echo "checkout — served: $pct, p99: ${c99}ms"
      echo "recommendations — served: ${served} of 2100, p99: ${r99}ms (refusals included)"
      echo

      if [ "$rc" -eq 0 ]; then
        echo "PASS — the surge cost recommendations, and only recommendations."
        exit 0
      fi

      if awk -v r="$ok" 'BEGIN { exit !(r <= 0.99) }'; then
        if [ "$all" -eq 0 ] && [ "$low" -eq 0 ] && [ "$qt" -eq 0 ]; then
          echo "not yet: only $pct of checkouts were served. Nothing refused anything, so all"
          echo "120 requests a second joined one queue that drains at 40, and checkout waited"
          echo "behind recommendations until it timed out."
          if [ "$workers" -gt 16 ]; then
            echo "API_WORKERS=$workers adds requests in progress, not cores: the extra workers"
            echo "wait for the same 2 cores, so the queue only moved."
          fi
        elif [ "$low" -eq 0 ] || { [ "$all" -gt 0 ] && [ "$low" -ge "$all" ]; }; then
          echo "not yet: api shed load, but only $pct of checkouts were served."
          if [ "$all" -gt 0 ]; then
            echo "SHED_ALL_AT=$all refuses whichever request arrives when api is full, and"
          else
            echo "QUEUE_TIMEOUT_MS=$qt fails whichever request has waited too long, and"
          fi
          echo "seven in eight arrivals are recommendations — so checkouts are refused as"
          echo "often as they are, though checkout alone fits in capacity. Shedding has"
          echo "to know which traffic matters."
        else
          echo "not yet: only $pct of checkouts were served. SHED_LOW_AT=$low leaves"
          echo "recommendations room, but SHED_ALL_AT=$all or QUEUE_TIMEOUT_MS=$qt is also"
          echo "refusing checkouts while they fill it."
        fi
      elif awk -v p="$c99" 'BEGIN { exit !(p >= 500) }'; then
        echo "not yet: every checkout was served, but its p99 was ${c99}ms. Recommendations"
        echo "are admitted until $low requests are in flight, and a checkout queues behind"
        echo "all of them: at 40 a second, $low in flight is about $(( low * 25 ))ms of wait."
      elif awk -v p="$r99" 'BEGIN { exit !(p >= 500) }'; then
        echo "not yet: checkout is fine, but recommendations took ${r99}ms at p99. A request"
        echo "that is going to be refused should be refused on arrival, not after a wait."
      elif awk -v n="$served" 'BEGIN { exit !(n < 150) }'; then
        echo "not yet: checkout is fine, but only ${served} recommendations were served. The"
        echo "capacity checkout leaves spare is about 25 a second; use it."
      else
        printf '%s\n' "$out" | tail -15
        echo "not yet: the load test failed a threshold not covered above — output above."
      fi
      exit 1
---
