---
kind: lesson
title: "Circuit breaker: failing fast beats failing slowly"
description: |
  checkout has a timeout and a fallback, so a slow pricing no longer takes it
  down. But it still sends every request into a dependency it already knows is
  broken, and every customer pays the full timeout to find out again. Build the
  breaker that stops calling, answers instantly, and tests the water with one
  request at a time until pricing is back.
name: circuit-breaker
slug: circuit-breaker
createdAt: "2026-10-08"
timingSensitive: true

sandbox:
  stack: chaos-stack
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-21/*.circuit-breaker
      lesson=$1
      work="$DEVOPSLINGS_ROOT/scratch/circuit-breaker"

      docker compose up -d --wait >/dev/null 2>&1 || true
      curl -fsS -X POST http://127.0.0.1:8474/reset >/dev/null 2>&1 || true

      # breaker.py lives outside any container, so `compose down -v` does not
      # reset it; a solved attempt would otherwise stay solved.
      mkdir -p "$work"
      cp "$lesson/starter/breaker.py" "$work/breaker.py"
      printf '#!/usr/bin/env bash\nexec "%s/files/try.sh" "$@"\n' "$lesson" > "$work/try"
      chmod +x "$work/try"

      "$lesson/files/try.sh" 3

      echo
      echo "scenario ready — pricing is healthy, and checkout (with your breaker) on"
      echo "port 8081 inside the checkout container calls it on every request."
      echo
      echo "Edit scratch/circuit-breaker/breaker.py, and run scratch/circuit-breaker/try"
      echo "to deploy it and send requests. At verify time pricing becomes 8s slow."

  inject_fault:
    timeout_seconds: 60
    run: |
      curl -fsS -X POST http://127.0.0.1:8474/reset >/dev/null
      curl -fsS -X POST http://127.0.0.1:8474/proxies/pricing/toxics \
        -H 'Content-Type: application/json' \
        -d '{"name":"latency","type":"latency","stream":"downstream","attributes":{"latency":8000,"jitter":0}}' \
        >/dev/null
      echo "fault injected: pricing responses delayed by 8s"

  verify_done:
    needs: [init_scenario, inject_fault]
    timeout_seconds: 300
    run: |
      set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-21/*.circuit-breaker
      files="$1/files"
      student="$DEVOPSLINGS_ROOT/scratch/circuit-breaker/breaker.py"
      tp=http://127.0.0.1:8474

      # Every round below changes the fault; none of it should outlive the check.
      trap 'curl -fsS -X POST http://127.0.0.1:8474/reset >/dev/null 2>&1 || true' EXIT

      probe() { docker compose exec -T checkout python3 /opt/cb/probe.py "$@" 2>&1 || true; }
      count() { printf '%s\n' "$1" | awk -v f="$2" -v v="$3" '$f == v' | wc -l | tr -d ' '; }
      proxy() {
        curl -fsS -X POST "$tp/proxies/pricing" -H 'Content-Type: application/json' \
          -d "{\"enabled\":$1}" >/dev/null
      }
      indent() { sed 's/^/    /'; }

      if [ ! -s "$student" ]; then
        echo "not yet: scratch/circuit-breaker/breaker.py is missing. Reset the lesson to get the starter."
        exit 1
      fi
      # Deploying restarts the harness, so every check starts from a closed breaker.
      if ! dep=$("$files/try.sh" 0 2>&1); then
        echo "not yet: checkout could not load your breaker.py:"
        printf '%s\n' "$dep" | tail -15 | indent
        exit 1
      fi
      timeout=$(docker compose exec -T checkout python3 -c \
        'import sys; sys.path.insert(0, "/opt/cb"); import breaker; print(*breaker.TIMEOUT)' \
        2>/dev/null | tr -d '\r' || true)
      read_s=$(printf '%s' "$timeout" | awk '{ print $2 + 0 }')

      # A breaker that raises turns every request into a 500, which the rounds
      # below would otherwise misread as a breaker decision.
      crashed() {
        if printf '%s\n' "$1" | grep -qE ' ERR |^#[0-9]+ +5[0-9][0-9] '; then
          echo "not yet: your breaker raised an exception, so checkout answered with errors:"
          printf '%s\n' "$1" | head -3 | indent
          docker compose exec -T checkout tail -8 /opt/cb/log 2>/dev/null | indent || true
          exit 1
        fi
      }

      # Round 1 — the threshold. Fast failures (proxy refusing connections),
      # one request at a time, so the count is exact: 3 failures, a success,
      # then failures until it opens.
      curl -fsS -X DELETE "$tp/proxies/pricing/toxics/latency" >/dev/null 2>&1 || true
      proxy false; a=$(probe seq 3)
      proxy true;  b=$(probe seq 1)
      proxy false; c=$(probe seq 6)
      proxy true
      crashed "$a"; crashed "$b"; crashed "$c"
      if [ "$(count "$a" 4 called)" != 3 ]; then
        echo "not yet: the breaker opened after fewer than 4 consecutive failures:"
        printf '%s\n' "$a" | indent
        echo "One slow or failed call is noise. The spec is: open after 5 in a row."
        exit 1
      fi
      if [ "$(count "$b" 3 pricing)" != 1 ]; then
        echo "not yet: after 3 failures the next request, with pricing healthy, got:"
        printf '%s\n' "$b" | indent
        echo "Three failures should not open the breaker — the spec is 5 in a row."
        exit 1
      fi
      if [ "$(printf '%s\n' "$c" | head -3 | awk '$4 == "called"' | wc -l | tr -d ' ')" != 3 ]; then
        echo "not yet: 3 failures, then a success, then these with pricing refusing connections:"
        printf '%s\n' "$c" | indent
        echo "The breaker opened before 4 failures in a row. A success in between should reset the"
        echo "count — a breaker counting all failures ever will eventually open on a healthy service."
        exit 1
      fi
      if [ "$(printf '%s\n' "$c" | tail -1 | awk '{ print $4 }')" != skipped ]; then
        echo "not yet: 6 consecutive failures, and the 6th request still called pricing:"
        printf '%s\n' "$c" | indent
        echo "It should open after 5 in a row, then refuse every call for the 5s cooldown."
        if awk -v r="$read_s" 'BEGIN { exit !(r > 0 && r < 1) }'; then
          echo "A ${read_s}s read timeout makes each failure cheaper, but checkout still pays it on"
          echo "every request, against a dependency it already knows is down."
        fi
        exit 1
      fi

      # Back to the injected fault, against a fresh breaker.
      probe restart >/dev/null
      curl -fsS -X POST "$tp/proxies/pricing/toxics" -H 'Content-Type: application/json' \
        -d '{"name":"latency","type":"latency","stream":"downstream","attributes":{"latency":8000,"jitter":0}}' \
        >/dev/null

      # Round 2 — sustained fault, under load. Each call that reaches pricing
      # waits out the read timeout; an open breaker answers without calling.
      k6ok=1
      out=$(docker compose exec -T k6 k6 run --quiet - < "$files/load.js" 2>&1) || k6ok=0
      st=$(probe stats)
      stat_of() { printf '%s' "$st" | grep -oE "\"$1\": *[0-9]+" | grep -oE '[0-9]+$' || echo 0; }
      calls=$(stat_of calls); refused=$(stat_of refused)
      herd=$(stat_of max_later_inflight)

      if [ "$k6ok" = 0 ]; then
        printf '%s\n' "$out" | grep -E 'pricing_calls|http_req_duration|checks' | head -4 || true
        echo
        if printf '%s\n' "$out" | grep -qE '✗ checks'; then
          echo "not yet: some requests were not answered with a price. The harness log:"
          docker compose exec -T checkout tail -8 /opt/cb/log 2>/dev/null | indent || true
        elif [ "$refused" = 0 ]; then
          echo "not yet: the breaker never opened. All ${calls} requests in 15s called pricing while it"
          echo "was 8s slow, and each one waited out the timeout to learn what the last one already knew."
          if awk -v r="$read_s" 'BEGIN { exit !(r > 0 && r < 1) }'; then
            echo "A ${read_s}s read timeout makes each failure cheaper, but it is still a failure,"
            echo "paid on every request, against a dependency you know is down."
          fi
        elif [ "$herd" -gt 1 ]; then
          echo "not yet: the breaker opened, but when it let calls through again it let ${herd} through at"
          echo "once (${calls} pricing calls in all). Half-open admits ONE trial request; everyone else"
          echo "keeps getting the fallback until that trial comes back."
        elif [ "$calls" -gt 15 ]; then
          echo "not yet: the breaker opened and tries one call at a time, but it tried ${calls} times in"
          echo "15s. It is not staying open long enough between trials — the cooldown is 5s."
        else
          echo "not yet: the breaker opened (${calls} pricing calls, ${refused} answered without one), but"
          echo "the load test still failed its thresholds, shown above."
        fi
        exit 1
      fi

      # Round 3 — recovery. The fault is lifted; within the cooldown the breaker
      # must try pricing again, and once that trial succeeds, close for everyone.
      curl -fsS -X DELETE "$tp/proxies/pricing/toxics/latency" >/dev/null 2>&1 || true
      rec=$(probe seq 48 0.25)
      crashed "$rec"
      if [ "$(count "$rec" 3 pricing)" = 0 ]; then
        echo "not yet: pricing has been healthy for 12s and the breaker has not tried it once:"
        printf '%s\n' "$rec" | tail -4 | indent
        echo "An open breaker that never half-opens turns a 10-second fault into a permanent outage."
        exit 1
      fi
      burst=$(probe burst 10)
      if [ "$(count "$burst" 3 pricing)" != 10 ]; then
        echo "not yet: the breaker's trial call succeeded, but 10 requests sent together afterwards got:"
        printf '%s\n' "$burst" | indent
        echo "A successful trial should close the breaker, not leave it admitting one call at a time."
        exit 1
      fi

      # Round 4 — a slow but working pricing must still be used. Making
      # failure cheap is the breaker's job; a timeout under the dependency's
      # normal latency only turns slow into broken.
      probe restart >/dev/null
      curl -fsS -X POST "$tp/proxies/pricing/toxics" -H 'Content-Type: application/json' \
        -d '{"name":"latency","type":"latency","stream":"downstream","attributes":{"latency":300,"jitter":0}}' \
        >/dev/null
      d=$(probe seq 5)
      if [ "$(count "$d" 3 pricing)" != 5 ]; then
        echo "not yet: pricing is answering in 300ms — slow, but working — and checkout got:"
        printf '%s\n' "$d" | indent
        echo "TIMEOUT is (${timeout}). A timeout below the dependency's normal latency turns a slow"
        echo "service into a failing one, and then the breaker opens on a healthy dependency."
        exit 1
      fi

      echo "pricing calls under the 8s fault: ${calls} (10 to discover it, then one trial at a time)"
      echo "PASS — the breaker opened under sustained failure, half-opened one trial at a time,"
      echo "and closed when pricing recovered."
