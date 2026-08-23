---
kind: lesson
title: "two routes, two 5xx, and the same three restarts will not fix either"
description: |
  The dashboard says the gateway is throwing 5xx on two endpoints. One is a 502
  and one is a 504, they have completely different causes, and only one of them
  has anything to do with a setting on the proxy. The nginx error log tells them
  apart in one line each — and the first instinct, restarting nginx, changes
  nothing about either.
name: 502-vs-504
slug: 502-vs-504
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
      systemctl stop nginx.service 2>/dev/null || true
      rm -f /etc/nginx/sites-enabled/* /etc/nginx/sites-available/gateway
      rm -f /root/answers/gateway.md
      install -d /root/answers

      # Both backends have to be answering before either is broken on purpose.
      for port in 8081 8091; do
        curl -s -X POST -m 3 "http://172.32.0.11:$port/admin/mode?value=normal" >/dev/null 2>&1 || true
      done
      ready=""
      for _ in $(seq 1 40); do
        if curl -s -m 2 http://172.32.0.11:8080/health 2>/dev/null | grep -q ok &&
           curl -s -m 2 http://172.32.0.11:8090/health 2>/dev/null | grep -q ok; then
          ready=yes
          break
        fi
        sleep 0.5
      done
      if [ -z "$ready" ]; then
        echo "the upstreams on 172.32.0.11 never came up"
        exit 1
      fi

      # ---- the gateway -------------------------------------------------
      #
      # Three seconds is a normal, defensible read timeout, and it is written
      # once at server level where a timeout usually is. Nothing here is
      # misconfigured yet.
      cat > /etc/nginx/sites-available/gateway <<'CONF'
      server {
          listen 80 default_server;
          server_name _;

          proxy_connect_timeout 3s;
          proxy_read_timeout 3s;

          location /orders {
              proxy_pass http://172.32.0.11:8090;
          }

          location /users {
              proxy_pass http://172.32.0.11:8080;
          }
      }
      CONF
      ln -sf /etc/nginx/sites-available/gateway /etc/nginx/sites-enabled/gateway

      systemctl enable --now nginx.service >/dev/null 2>&1
      systemctl reload nginx.service 2>/dev/null || systemctl restart nginx.service
      truncate -s 0 /var/log/nginx/error.log 2>/dev/null || true

      # ---- the two faults ------------------------------------------------
      #
      # Two different things, deliberately producing two different status codes
      # from the same proxy.
      #
      # The orders backend accepts the connection and closes it without writing
      # a response — a crashed worker, from nginx's side of the socket.
      #
      # The users backend is healthy and takes six seconds, which is longer than
      # the proxy is willing to wait. Nothing is broken about it. It is a report
      # that takes six seconds to build.
      curl -s -X POST -m 3 'http://172.32.0.11:8091/admin/mode?value=dead' >/dev/null
      curl -s -X POST -m 3 'http://172.32.0.11:8081/admin/mode?value=slow&ms=6000' >/dev/null

      cat > /root/questions.txt <<'Q'
      The dashboard shows 5xx on two endpoints of the gateway. They are not the
      same failure:

        $ curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' http://127.0.0.1/orders
        502 0.002s
        $ curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' http://127.0.0.1/users
        504 3.004s

      One fails instantly and one fails after exactly as long as the proxy was
      willing to wait. nginx has been restarted twice and both still fail.

      The backends are two separate processes on 172.32.0.11:

        orders  ->  172.32.0.11:8090   (admin API on 8091)
        users   ->  172.32.0.11:8080   (admin API on 8081)

      Each admin API can be asked what it received, and told how to behave:

        curl -s http://172.32.0.11:8091/admin/received
        curl -s -X POST 'http://172.32.0.11:8091/admin/mode?value=normal'
        curl -s -X POST 'http://172.32.0.11:8081/admin/mode?value=slow&ms=6000'

      Read /var/log/nginx/error.log before you change anything. It writes one
      line per failure and the two lines are not alike.

      Three things to do.

      1. Make http://127.0.0.1/orders return "orders: 1001 1002".

      2. Make http://127.0.0.1/users return "users: alice bob carol".

         The users backend takes six seconds because that is how long the report
         takes. It is not going to get faster, and it will be put back to six
         seconds when you are graded, so making it fast is not the fix.

      3. Write /root/answers/gateway.md, exactly three lines:

           orders_cause: <one word>
           users_cause: <one word>
           users_upstream_seconds: <number>

         The two causes are the ones the error log names, each one of:

           closed | refused | timeout

         users_upstream_seconds is how long the users backend itself takes,
         measured against it directly rather than through the proxy.

      The orders route must still fail fast if its backend stalls. Raising every
      timeout on the box until nothing can time out is not a repair — a proxy
      that waits forever runs out of workers instead, and then everything is
      down rather than one route.
      Q

      echo "scenario ready — /orders 502, /users 504"

  inject_fault:
    timeout_seconds: 60
    run: |
      # The users backend is slow by design, so the grader puts the slowness
      # back before measuring. A fix that works only because the report got
      # faster is not a fix to the gateway.
      curl -s -X POST -m 5 'http://172.32.0.11:8081/admin/mode?value=slow&ms=6000' >/dev/null 2>&1
      echo "users backend set back to six seconds"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      # The targeting probe below stalls the orders backend on purpose. Put it
      # back on every exit path, or a failed check leaves the box broken in a
      # way the student did not cause.
      restore() {
        curl -s -X POST -m 5 'http://172.32.0.11:8091/admin/mode?value=normal' >/dev/null 2>&1 || true
      }
      trap restore EXIT

      # ---- the 502 route ---------------------------------------------------
      body=$(curl -s -m 10 http://127.0.0.1/orders 2>/dev/null || true)
      if [ "$body" != "orders: 1001 1002" ]; then
        code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' http://127.0.0.1/orders 2>/dev/null || echo 000)
        echo "not yet: /orders returns $code, and not the orders list."
        if [ "$code" = "502" ]; then
          echo "         Still 502. A 502 is the proxy saying it could not get a response"
          echo "         out of the upstream at all — nothing it does to itself changes"
          echo "         that. The error log says which kind:"
          echo "         'prematurely closed' means the backend accepted the connection"
          echo "         and hung up; 'Connection refused' means nothing was listening."
        fi
        exit 1
      fi

      # grep finding nothing is an expected outcome here, and under pipefail an
      # unguarded pipeline would abort the check with no message at all.
      who=$(curl -s -m 10 -o /dev/null -D - http://127.0.0.1/orders 2>/dev/null | grep -i '^x-upstream:' | tr -d '\r' | awk '{print $2}' || true)
      if [ "$who" != "b" ]; then
        echo "not yet: /orders is answered by '${who:-nothing}', not by the orders"
        echo "         backend on 172.32.0.11:8090."
        echo "         Pointing the route at the other backend, or answering it from"
        echo "         nginx, hides the outage rather than ending it."
        exit 1
      fi

      # ---- the 504 route ---------------------------------------------------
      out=$(curl -s -m 30 -w '\n%{time_total}' http://127.0.0.1/users 2>/dev/null || true)
      utime=$(printf '%s' "$out" | tail -1)
      ubody=$(printf '%s' "$out" | sed '$d')
      usecs=${utime%%.*}
      : "${usecs:=0}"

      if [ "$ubody" != "users: alice bob carol" ]; then
        ucode=$(curl -s -o /dev/null -m 30 -w '%{http_code}' http://127.0.0.1/users 2>/dev/null || echo 000)
        echo "not yet: /users returns $ucode after ${utime}s, and not the user list."
        echo "         The backend answers this route in six seconds and the proxy is"
        echo "         giving up before that. 504 is the proxy's own deadline, not the"
        echo "         upstream's error — the upstream never got to finish."
        exit 1
      fi

      if [ "$usecs" -lt 4 ]; then
        echo "not yet: /users answered in ${utime}s, and the backend takes six."
        echo "         Something other than the backend produced that body."
        exit 1
      fi

      # ---- and the fix was aimed --------------------------------------------
      #
      # Stall the orders backend and check that route still gives up quickly. A
      # timeout raised at server level fixes /users and quietly takes /orders
      # with it, which is how one slow dependency becomes a full outage.
      curl -s -X POST -m 5 'http://172.32.0.11:8091/admin/mode?value=slow&ms=9000' >/dev/null 2>&1 || true
      probe=$(curl -s -o /dev/null -m 25 -w '%{http_code} %{time_total}' http://127.0.0.1/orders 2>/dev/null || echo "000 99")
      restore
      ptime=$(printf '%s' "$probe" | awk '{print $2}')
      psecs=${ptime%%.*}
      : "${psecs:=99}"

      if [ "$psecs" -ge 6 ]; then
        echo "not yet: with the orders backend stalled, /orders waited ${ptime}s before"
        echo "         giving up. It used to give up in three."
        echo "         The read timeout was raised for everything rather than for the"
        echo "         one route that needs it. Every worker held by a stalled backend"
        echo "         is a worker not serving anything else."
        exit 1
      fi

      # ---- naming the two failures ------------------------------------------
      if [ ! -s /root/answers/gateway.md ]; then
        echo "not yet: /root/answers/gateway.md is missing or empty."
        echo "         Both causes are in /var/log/nginx/error.log, one line each."
        exit 1
      fi

      low=$(tr 'A-Z' 'a-z' < /root/answers/gateway.md)
      oc=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*orders_cause[[:space:]]*[:=][[:space:]]*\([a-z]*\).*/\1/p' | head -1)
      uc=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*users_cause[[:space:]]*[:=][[:space:]]*\([a-z]*\).*/\1/p' | head -1)
      us=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*users_upstream_seconds[[:space:]]*[:=][[:space:]]*\([0-9]*\).*/\1/p' | head -1)

      if [ -z "$oc" ] || [ -z "$uc" ] || [ -z "$us" ]; then
        echo "not yet: /root/answers/gateway.md needs all three lines —"
        echo "         orders_cause, users_cause and users_upstream_seconds."
        exit 1
      fi

      fail=0

      if [ "$oc" != "closed" ]; then
        fail=1
        echo "not yet: you said orders_cause=$oc."
        case "$oc" in
          refused)
            echo "         Refused is the other 502: nothing listening on the port, and"
            echo "         nginx logs 'connect() failed (111: Connection refused)'. This"
            echo "         backend accepted the connection and then hung up, which nginx"
            echo "         logs as 'upstream prematurely closed connection'."
            ;;
          timeout)
            echo "         A timeout is a 504, and this route failed in two milliseconds."
            echo "         Nothing waited for anything."
            ;;
          *)
            echo "         One of: closed | refused | timeout, as the error log describes"
            echo "         it."
            ;;
        esac
      fi

      if [ "$uc" != "timeout" ]; then
        fail=1
        echo "not yet: you said users_cause=$uc."
        echo "         This one failed after exactly three seconds — the proxy's own"
        echo "         read timeout — and the log line is 'upstream timed out (110:"
        echo "         Connection timed out) while reading response header'."
      fi

      if [ "$us" -lt 5 ] || [ "$us" -gt 7 ]; then
        fail=1
        echo "not yet: you said users_upstream_seconds=$us."
        case "$us" in
          3)
            echo "         Three seconds is how long the proxy waited, which is a fact"
            echo "         about the gateway. The question is how long the backend takes."
            echo "         Ask it directly:"
            echo "         curl -s -o /dev/null -w '%{time_total}\\n' http://172.32.0.11:8080/users"
            ;;
          *)
            echo "         Measure it against the backend rather than through the proxy:"
            echo "         curl -s -o /dev/null -w '%{time_total}\\n' http://172.32.0.11:8080/users"
            ;;
        esac
      fi

      [ "$fail" -eq 0 ] || exit 1

      echo "PASS — the dead backend is answering again, the slow one is waited for on"
      echo "       the route that needs it and nowhere else, and the two failures are"
      echo "       named by what the error log actually said."
