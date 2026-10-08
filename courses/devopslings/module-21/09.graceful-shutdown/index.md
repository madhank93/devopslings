---
kind: lesson
title: "A deploy that drops in-flight requests"
description: |
  Two replicas of orders sit behind a load balancer, and a rolling deploy
  restarts them one at a time — so there is always one up, and it should be
  invisible. It is not: every deploy fails a handful of requests, because the
  process being replaced dies with work in hand and the balancer finds out
  too late.
name: graceful-shutdown
slug: graceful-shutdown
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
      L=../../courses/devopslings/module-21/09.graceful-shutdown
      G=$L/graceful.compose.yaml
      S=../../scratch/graceful-shutdown

      # A deploy left running by an earlier verify must not restart anything
      # under the fresh scenario.
      if [ -f "$S/deploy.pid" ]; then kill "$(cat "$S/deploy.pid")" 2>/dev/null || true; fi
      mkdir -p "$S"
      rm -f "$S/deploy.pid" "$S/deploy.log" "$S/load-started"
      cp "$L/starter/app.py" "$S/app.py"

      # .env is the student's file and outlives `compose down`, so it is reset
      # here. COMPOSE_FILE layers the lesson's services over the stack.
      cat > .env <<ENV
      COMPOSE_FILE=compose.yaml:$G
      STOP_GRACE_PERIOD=10s
      ENV

      docker compose -f compose.yaml -f "$G" \
        up -d --wait --force-recreate orders-a orders-b probe lb >/dev/null 2>&1 || true

      echo "scenario ready — two replicas behind the balancer, both healthy."
      echo
      curl -fsS --max-time 5 http://127.0.0.1:18092/order || true
      echo
      echo "At verify time a rolling deploy restarts orders-a, then orders-b, under"
      echo "load. Every request must succeed. The code is scratch/graceful-shutdown/app.py."

  # The fault is a deploy, which has to overlap the load test rather than
  # precede it. It is launched in the background here and waits for
  # verify_done to signal that load is running. Reloading the replicas first
  # makes the deploy exercise the app.py on disk.
  inject_fault:
    timeout_seconds: 180
    run: |
      L=../../courses/devopslings/module-21/09.graceful-shutdown
      G=$L/graceful.compose.yaml
      S=../../scratch/graceful-shutdown
      dc() { docker compose -f compose.yaml -f "$G" "$@"; }

      mkdir -p "$S"
      if [ -f "$S/deploy.pid" ]; then kill "$(cat "$S/deploy.pid")" 2>/dev/null || true; fi
      rm -f "$S/deploy.pid" "$S/deploy.log" "$S/load-started"

      # kill, not stop: how the old process handles SIGTERM is graded during
      # the deploy, not here. A broken app.py must not fail this task.
      dc kill orders-a orders-b probe >/dev/null 2>&1 || true
      dc up -d --wait orders-a orders-b probe lb >/dev/null 2>&1 || true

      nohup bash "$L/deploy.sh" "$S" "$G" </dev/null >/dev/null 2>&1 &
      echo $! > "$S/deploy.pid"
      echo "fault scheduled: a rolling restart of orders-a then orders-b, under load"

  verify_done:
    needs: [init_scenario, inject_fault]
    timeout_seconds: 420
    run: |
      L=../../courses/devopslings/module-21/09.graceful-shutdown
      G=$L/graceful.compose.yaml
      S=../../scratch/graceful-shutdown
      dc() { docker compose -f compose.yaml -f "$G" "$@"; }
      lb_status() {
        curl -fsS --max-time 2 'http://127.0.0.1:18094/stats;csv' 2>/dev/null \
          | awk -F, -v s="$1" '$1=="orders" && $2==s {print $18}' || true
      }
      stop_deploy() {
        if [ -f "$S/deploy.pid" ]; then kill "$(cat "$S/deploy.pid")" 2>/dev/null || true; fi
        rm -f "$S/deploy.pid" "$S/load-started"
      }
      # One request: its HTTP status, or what went wrong instead.
      hit() {
        local out rc=0
        out=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$1" "$2" 2>/dev/null) || rc=$?
        case $rc in
          0) echo "$out" ;;
          28) echo "no answer" ;;
          *) echo "connection refused or reset" ;;
        esac
      }

      if [ ! -f "$S/app.py" ]; then
        stop_deploy
        echo "not yet: scratch/graceful-shutdown/app.py is missing. Reset the lesson to get it back."
        exit 1
      fi

      for _ in $(seq 40); do
        [ "$(lb_status a)" = UP ] && [ "$(lb_status b)" = UP ] && break
        sleep 0.5
      done
      if [ "$(lb_status a)" != UP ] || [ "$(lb_status b)" != UP ]; then
        stop_deploy
        echo "not yet: the replicas are not passing /ready, so the balancer has nothing"
        echo "to route to (orders-a: '$(lb_status a)', orders-b: '$(lb_status b)'). app.py"
        echo "may not start — see: docker compose -p devopslings-chaos-stack logs orders-a"
        exit 1
      fi

      # Starts the deploy, which waits a few seconds into the load test.
      touch "$S/load-started"
      k6ok=1
      out=$(dc exec -T k6 k6 run --quiet - < "$L/orders.js" 2>&1) || k6ok=0

      for _ in $(seq 60); do
        grep -q ' done$' "$S/deploy.log" 2>/dev/null && break
        sleep 0.5
      done
      deployed=0
      grep -q ' done$' "$S/deploy.log" 2>/dev/null && deployed=1
      stop_deploy
      if [ "$deployed" = 0 ]; then
        dc up -d orders-a orders-b >/dev/null 2>&1 || true
      fi
      stops=$(grep -E 'stopped after' "$S/deploy.log" 2>/dev/null | cut -d' ' -f2- || true)

      if [ "$k6ok" = 1 ] && [ "$deployed" = 1 ]; then
        printf '%s\n' "$out" | grep -E 'http_req_failed|checks' || true
        printf '%s\n' "$stops"
        echo
        echo "PASS — both replicas were replaced under load and no request failed."
        exit 0
      fi

      printf '%s\n' "$out" | grep -E 'http_req_failed|checks|✗' || true
      printf '%s\n' "$stops"
      echo

      # The load test says that requests failed, not why. Send SIGTERM to a
      # replica outside the balancer and watch each step of its shutdown.
      P=http://127.0.0.1:18093
      dc up -d --wait probe >/dev/null 2>&1 || true
      rm -f "$S/probe-slow"
      ( hit 20 "$P/order?ms=4000" > "$S/probe-slow" ) &
      slow_pid=$!
      sleep 0.5
      dc kill -s SIGTERM probe >/dev/null 2>&1 || true
      sleep 0.3
      ready=$(hit 1 "$P/ready")
      sleep 0.5
      late=$(hit 1 "$P/order?ms=10")
      wait "$slow_pid" 2>/dev/null || true
      slow=$(cat "$S/probe-slow" 2>/dev/null || true)
      gone=0
      for _ in $(seq 24); do
        if [ -z "$(dc ps -q --status running probe 2>/dev/null || true)" ]; then gone=1; break; fi
        sleep 0.5
      done
      dc kill probe >/dev/null 2>&1 || true
      dc up -d probe >/dev/null 2>&1 || true
      grace=$(grep -E '^STOP_GRACE_PERIOD=' .env 2>/dev/null | cut -d= -f2- || true)

      if [ "$gone" = 0 ]; then
        echo "not yet: a replica was still running 12s after SIGTERM, so it was ignoring it."
        echo "The platform waits out the grace period (STOP_GRACE_PERIOD=${grace:-10s}), then"
        echo "SIGKILLs it with requests in hand — and the balancer was routing to it the"
        echo "whole time. A longer grace period only moves the moment requests are cut off."
      elif [ "$ready" = "no answer" ]; then
        echo "not yet: 0.3s after SIGTERM the replica answered nothing at all — /ready hung."
        echo "Something in the shutdown path blocks the server loop (a sleep inside the signal"
        echo "handler does this: it runs on the thread that accepts connections). Requests"
        echo "routed there wait unanswered, then fail when the process exits."
      elif [ "$ready" = 200 ]; then
        echo "not yet: /ready still answered 200 0.3s after SIGTERM — readiness never flipped."
        echo "The balancer keeps routing new requests to a replica that is about to stop"
        echo "accepting them, and those requests fail."
      elif [ "$ready" != 503 ]; then
        echo "not yet: the replica stopped accepting connections the instant SIGTERM arrived"
        echo "(/ready 0.3s later: $ready). The balancer polls /ready every 500ms, so"
        echo "it keeps sending requests to a port nobody is listening on. Flipping /ready"
        echo "only helps if the replica stays up long enough for the balancer to see it."
        if [ "$slow" != 200 ]; then
          echo "The request in flight when SIGTERM arrived was cut off too ($slow)."
        fi
      elif [ "$late" != 200 ]; then
        echo "not yet: /ready flipped to 503, but 0.8s after SIGTERM the replica had already"
        echo "stopped serving (a request got: $late). The balancer only polls every 500ms;"
        echo "requests it routed before noticing arrive after you stopped accepting."
      elif [ "$slow" != 200 ]; then
        echo "not yet: readiness and timing are right, but a 4s request that was in flight"
        echo "when SIGTERM arrived was cut off ($slow)."
        echo "Stop accepting, then exit only after the requests you accepted have finished."
      elif [ "$deployed" = 0 ]; then
        echo "not yet: the rolling deploy did not finish inside the load test."
        echo "Each replica must stop within its grace period (STOP_GRACE_PERIOD=${grace:-10s})."
      else
        echo "not yet: the shutdown steps look right on a single replica, but requests still"
        echo "failed during the deploy. Deploy log:"
        cat "$S/deploy.log" 2>/dev/null || true
      fi
      exit 1
---
