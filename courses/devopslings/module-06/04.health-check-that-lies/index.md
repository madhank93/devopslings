---
kind: lesson
title: "the load balancer says both nodes are healthy and half the requests fail"
description: |
  Two backends behind HAProxy, one of which cannot do its job because the thing
  it depends on is gone. Its process is running, so the health check passes, so
  it stays in rotation, so half of everything 503s — and the graph of "healthy
  backends" reads 2/2 throughout.
name: health-check-that-lies
slug: health-check-that-lies
createdAt: "2026-08-23"
timingSensitive: true

sandbox:
  stack: web-stack
  service: web

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      set -e

      # ---- clean slate -------------------------------------------------
      systemctl stop haproxy.service nginx.service 2>/dev/null || true
      rm -f /root/answers/healthcheck.md
      install -d /root/answers

      for port in 8081 8091; do
        curl -s -X POST -m 3 "http://172.32.0.11:$port/admin/reset" >/dev/null 2>&1 || true
      done
      ready=""
      for _ in $(seq 1 40); do
        if curl -s -m 2 http://172.32.0.11:8080/ready 2>/dev/null | grep -q ready &&
           curl -s -m 2 http://172.32.0.11:8090/ready 2>/dev/null | grep -q ready; then
          ready=yes
          break
        fi
        sleep 0.5
      done
      if [ -z "$ready" ]; then
        echo "the backends on 172.32.0.11 never came up"
        exit 1
      fi

      # ---- the load balancer -------------------------------------------
      #
      # Nothing here is unusual, which is the point: GET /health every ten
      # seconds, out after three failures. It is what most load balancers are
      # pointed at on the first day, and it only ever proves that something is
      # listening on the port.
      cat > /etc/haproxy/haproxy.cfg <<'CFG'
      global
          log stdout format raw local0
          stats socket /run/haproxy/admin.sock mode 660 level admin
          daemon

      defaults
          mode http
          timeout connect 3s
          timeout client 15s
          timeout server 15s

          option httpchk GET /health
          default-server check inter 10s fall 3 rise 2

      frontend gateway
          bind *:8000
          default_backend app

      backend app
          server a 172.32.0.11:8080
          server b 172.32.0.11:8090
      CFG

      haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null 2>&1
      systemctl start haproxy.service
      for _ in $(seq 1 20); do
        curl -s -o /dev/null -m 2 http://127.0.0.1:8000/orders && break
        sleep 0.5
      done

      # ---- the fault -----------------------------------------------------
      #
      # Node b loses the dependency it needs to answer. Its process keeps
      # running and keeps answering /health with 200, because /health only ever
      # asked whether the process was running.
      curl -s -X POST -m 3 'http://172.32.0.11:8091/admin/deps?value=broken' >/dev/null

      cat > /root/questions.txt <<'Q'
      Half the requests through the load balancer fail:

        $ for i in $(seq 1 6); do
            curl -s -o /dev/null -w '%{http_code} ' http://127.0.0.1:8000/orders
          done
        200 503 200 503 200 503

      HAProxy has both backends up. It has never taken either out:

        $ echo "show stat" | socat stdio /run/haproxy/admin.sock | cut -d, -f1,2,18

      The backends are two processes on 172.32.0.11:

        a  ->  172.32.0.11:8080   admin 8081
        b  ->  172.32.0.11:8090   admin 8091

      Both answer /health with 200. One of them cannot serve a request, because
      the dependency it needs is gone. Ask each of them directly and compare:

        curl -s -o /dev/null -w '%{http_code}\n' http://172.32.0.11:8090/health
        curl -s -o /dev/null -w '%{http_code}\n' http://172.32.0.11:8090/ready
        curl -s -o /dev/null -w '%{http_code}\n' http://172.32.0.11:8090/orders

      The load balancer configuration is /etc/haproxy/haproxy.cfg. It is yours.
      The backends are not — you cannot change what they serve, and the
      dependency is not coming back on your schedule.

      Two things to do.

      1. Make the load balancer stop sending traffic to a node that cannot serve
         it, and keep sending traffic to one that can. Specifically:

           - a node whose dependency has just broken must be out of rotation
             within 15 seconds
           - a node whose dependency is healthy must be in rotation, and must
             not be ejected while it is healthy

         Both of those are checked, by breaking and repairing a backend while
         you are graded.

      2. Write /root/answers/healthcheck.md, exactly two lines:

           check_path: <path>
           health_proves: <one word>

         check_path is what the load balancer now asks each backend for.
         health_proves is what GET /health established on its own, one of:

           liveness | readiness

      Raising the check interval is the usual first move and it is the wrong
      direction: the check was not too frequent, it was asking the wrong
      question, and every second it takes to notice is a second of failed
      requests.
      Q

      echo "scenario ready — 2/2 backends 'healthy', half the requests failing"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 600
    run: |
      lb=http://127.0.0.1:8000/orders

      # The scenario hands the box over with b's dependency broken. Grading
      # breaks and repairs it several times; put it back the way it was found.
      restore() {
        curl -s -X POST -m 5 'http://172.32.0.11:8091/admin/deps?value=broken' >/dev/null 2>&1 || true
      }
      trap restore EXIT

      deps() {
        curl -s -X POST -m 5 "http://172.32.0.11:$1/admin/deps?value=$2" >/dev/null 2>&1 || true
      }

      # Twelve requests, and what came back: the set of backends that answered,
      # and whether anything failed.
      sample() {
        codes=""
        who=""
        for _ in $(seq 1 12); do
          out=$(curl -s -m 5 -o /dev/null -D - "$lb" 2>/dev/null || true)
          c=$(printf '%s' "$out" | head -1 | awk '{print $2}' || true)
          u=$(printf '%s' "$out" | grep -i '^x-upstream:' | tr -d '\r' | awk '{print $2}' || true)
          codes="$codes ${c:-000}"
          who="$who ${u:-none}"
        done
      }

      all_ok() { ! printf '%s' "$codes" | grep -qvE '^( 200)*$'; }
      saw() { printf '%s' "$who" | grep -q " $1"; }

      # ---- both healthy: both serve ---------------------------------------
      deps 8081 ok
      deps 8091 ok
      ok=""
      for _ in $(seq 1 25); do
        sample
        if all_ok && saw a && saw b; then ok=yes; break; fi
        sleep 1
      done
      if [ -z "$ok" ]; then
        echo "not yet: with both backends healthy, 25 seconds of requests never"
        echo "         settled into both of them answering without errors."
        echo "         codes:    $codes"
        echo "         answered: $who"
        if ! saw b; then
          echo "         Backend b never answered. A check that no backend can pass,"
          echo "         or a backend removed from the pool, takes the outage from"
          echo "         half the traffic to all of it on the day a is the sick one."
        fi
        exit 1
      fi

      # ---- and stays healthy for long enough to be believed -----------------
      #
      # A server that was failing checks before grading began carries a partly
      # advanced failure counter, and would then be ejected sooner than its
      # configuration says. Holding the pool clean across a window longer than
      # any interval that could meet the deadline resets that counter, so what
      # the next phase measures is the configuration rather than the history.
      for _ in $(seq 1 5); do
        sleep 2
        sample
        if ! all_ok || ! saw a || ! saw b; then
          echo "not yet: the pool did not stay healthy while both backends were."
          echo "         codes:    $codes"
          echo "         answered: $who"
          echo "         Something is ejecting a backend that can serve. A check that"
          echo "         the backends cannot reliably pass costs capacity for nothing."
          exit 1
        fi
      done

      # ---- one breaks: it must leave, inside the deadline -------------------
      deps 8091 broken
      start=$(date +%s)
      gone=""
      while [ $(( $(date +%s) - start )) -lt 15 ]; do
        sample
        if all_ok && ! saw b; then gone=yes; break; fi
        sleep 1
      done
      if [ -z "$gone" ]; then
        elapsed=$(( $(date +%s) - start ))
        echo "not yet: backend b's dependency broke, and ${elapsed}s later it was still"
        echo "         taking traffic."
        echo "         codes:    $codes"
        echo "         answered: $who"
        if saw b; then
          echo "         b is answering, which means the check it is passing does not"
          echo "         depend on the thing that is broken. Ask b for /health and for"
          echo "         /ready and compare the two status codes."
        fi
        echo "         The deadline is the check interval multiplied by the number of"
        echo "         failures needed to eject — inter times fall."
        exit 1
      fi

      # ---- it recovers: it must come back ----------------------------------
      deps 8091 ok
      back=""
      for _ in $(seq 1 30); do
        sample
        if all_ok && saw a && saw b; then back=yes; break; fi
        sleep 1
      done
      if [ -z "$back" ]; then
        echo "not yet: backend b's dependency came back and it did not return to"
        echo "         rotation within 30 seconds."
        echo "         codes:    $codes"
        echo "         answered: $who"
        echo "         A node is ejected on 'fall' consecutive failures and restored on"
        echo "         'rise' consecutive successes. Both are counted in check"
        echo "         intervals, so a long interval is slow in both directions."
        exit 1
      fi

      # ---- naming it --------------------------------------------------------
      if [ ! -s /root/answers/healthcheck.md ]; then
        echo "not yet: /root/answers/healthcheck.md is missing or empty."
        exit 1
      fi

      low=$(tr 'A-Z' 'a-z' < /root/answers/healthcheck.md)
      cp_=$(printf '%s\n' "$low" | sed -n 's#^[[:space:]]*check_path[[:space:]]*[:=][[:space:]]*\([^[:space:]]*\).*#\1#p' | head -1)
      hp=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*health_proves[[:space:]]*[:=][[:space:]]*\([a-z]*\).*/\1/p' | head -1)

      if [ -z "$cp_" ] || [ -z "$hp" ]; then
        echo "not yet: /root/answers/healthcheck.md needs a check_path line and a"
        echo "         health_proves line."
        exit 1
      fi

      fail=0

      # The stated path has to be one that actually changes its answer when the
      # dependency does — which is checked by asking it, not by reading a name.
      case "$cp_" in
        /*)
          deps 8091 broken
          sick=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://172.32.0.11:8090$cp_" 2>/dev/null || echo 000)
          deps 8091 ok
          well=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://172.32.0.11:8090$cp_" 2>/dev/null || echo 000)
          if [ "$well" != "200" ] || [ "$sick" = "200" ]; then
            fail=1
            echo "not yet: you said check_path=$cp_, and asking backend b for it gives"
            echo "         $well with the dependency healthy and $sick with it broken."
            echo "         A check path has to answer differently in those two states,"
            echo "         or the load balancer cannot tell them apart either."
          fi
          ;;
        *)
          fail=1
          echo "not yet: check_path=$cp_ is not a path."
          ;;
      esac

      if [ "$hp" != "liveness" ]; then
        fail=1
        echo "not yet: you said health_proves=$hp."
        case "$hp" in
          readiness)
            echo "         Readiness is the question the old check was failing to ask."
            echo "         /health returned 200 from a node that could not serve a single"
            echo "         request, so what it established was only that the process was"
            echo "         alive."
            ;;
          *)
            echo "         One of: liveness | readiness."
            ;;
        esac
      fi

      [ "$fail" -eq 0 ] || exit 1

      echo "PASS — a backend that loses its dependency leaves rotation inside the"
      echo "       deadline, a healthy one stays in and comes back, and the check"
      echo "       asks a question whose answer depends on the dependency."
