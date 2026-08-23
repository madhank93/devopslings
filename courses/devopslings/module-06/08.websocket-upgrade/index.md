---
kind: lesson
title: "the socket will not open, and once it does it dies after sixty seconds"
description: |
  A WebSocket through a proxy is two problems wearing one ticket. The handshake
  is an HTTP request that asks to stop being HTTP, and a proxy that forwards it
  like any other request strips the part that asks. Then, once it works, an idle
  socket looks exactly like a stalled upstream to a read timeout.
name: websocket-upgrade
slug: websocket-upgrade
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
      rm -f /etc/nginx/sites-enabled/* /etc/nginx/sites-available/live
      rm -f /etc/nginx/conf.d/*.conf /root/answers/ws.md
      install -d /root/answers

      curl -s -X POST -m 3 'http://172.32.0.11:8081/admin/reset' >/dev/null 2>&1 || true
      ready=""
      for _ in $(seq 1 40); do
        if curl -s -m 2 http://172.32.0.11:8080/health 2>/dev/null | grep -q ok; then
          ready=yes
          break
        fi
        sleep 0.5
      done
      if [ -z "$ready" ]; then
        echo "the origin on 172.32.0.11:8080 never came up"
        exit 1
      fi

      # ---- the proxy in front of the live feed ---------------------------
      #
      # An ordinary reverse proxy block. It is correct for every request the
      # application serves except the one that is trying to stop being a
      # request: nothing here forwards the Upgrade handshake, and nothing here
      # expects a connection to sit idle.
      cat > /etc/nginx/sites-available/live <<'CONF'
      server {
          listen 80 default_server;
          server_name _;

          location / {
              proxy_pass http://172.32.0.11:8080;
              proxy_set_header Host $host;
          }
      }
      CONF
      ln -sf /etc/nginx/sites-available/live /etc/nginx/sites-enabled/live

      if ! nginx -t 2>/tmp/nginx-t; then
        echo "the scenario's own nginx config did not load:"
        cat /tmp/nginx-t
        exit 1
      fi
      systemctl enable --now nginx.service >/dev/null 2>&1
      systemctl reload nginx.service 2>/dev/null || systemctl restart nginx.service

      for _ in $(seq 1 20); do
        curl -s -o /dev/null -m 2 http://127.0.0.1/health && break
        sleep 0.5
      done

      cat > /root/questions.txt <<'Q'
      The live feed does not connect through the proxy. The frontend team says
      the socket "fails immediately", and when they point the app straight at
      the application it works.

      wsprobe opens a websocket, echoes a message, optionally sits silent for a
      while, and echoes again. Straight at the application:

        $ wsprobe http://172.32.0.11:8080/ws --idle 2
        ok: echoed before and after 2s idle

      Through the proxy:

        $ wsprobe http://127.0.0.1/ws --idle 2
        handshake failed: HTTP/1.1 426 Upgrade Required

      There is a second report from before this one, from when the feed was
      briefly working on a test box: sockets opened fine and then died after
      about a minute, every time, and the client reconnected in a loop. Nobody
      found it and it was blamed on the reconnect logic.

      The proxy is /etc/nginx/sites-available/live on this box. The application
      is not yours.

      Two requirements.

      1. `wsprobe http://127.0.0.1/ws --idle 90` succeeds. A socket with nothing
         to say for ninety seconds is a normal socket, not a broken one.

      2. Ordinary requests must give up quickly: with the application stalled,
         http://127.0.0.1/health must return within 10 seconds. The default is
         60, and the deadline the websocket needs is minutes — applied to the
         whole server, that is how one wedged backend holds every worker on the
         box. The two routes need two deadlines.

      Then write /root/answers/ws.md, exactly two lines:

        handshake_code: <number>
        idle_limit_seconds: <number>

      handshake_code is the status the proxied handshake got before you fixed
      it. idle_limit_seconds is how long an idle proxied connection survived
      before you changed any timeout — the default that was in force.
      Q

      echo "scenario ready — the upgrade never arrives, and idle sockets are on a clock"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 900
    run: |
      restore() {
        curl -s -X POST -m 5 'http://172.32.0.11:8081/admin/mode?value=normal' >/dev/null 2>&1 || true
      }
      trap restore EXIT

      # ---- the socket opens, and stays open --------------------------------
      out=$(wsprobe http://127.0.0.1/ws --idle 90 --timeout 30 2>&1 || true)
      if ! printf '%s' "$out" | grep -q '^ok:'; then
        echo "not yet: wsprobe through the proxy said:"
        printf '         %s\n' "$out"
        case "$out" in
          *"426"*)
            echo "         426 is the application refusing to treat it as a websocket,"
            echo "         which means the handshake reached it without the headers that"
            echo "         make it one. Upgrade and Connection are hop-by-hop: a proxy"
            echo "         does not pass them on unless it is told to, and it cannot send"
            echo "         them at all over HTTP/1.0."
            ;;
          *"did not survive"*)
            echo "         The handshake works and the connection does not last. To a"
            echo "         proxy an idle websocket is indistinguishable from an upstream"
            echo "         that has stopped talking, and it applies the same deadline."
            ;;
        esac
        exit 1
      fi

      # ---- and ordinary requests still give up quickly ----------------------
      curl -s -X POST -m 5 'http://172.32.0.11:8081/admin/mode?value=slow&ms=30000' >/dev/null 2>&1 || true
      probe=$(curl -s -o /dev/null -m 60 -w '%{http_code} %{time_total}' http://127.0.0.1/health 2>/dev/null || echo "000 99")
      restore
      ptime=$(printf '%s' "$probe" | awk '{print $2}')
      psecs=${ptime%%.*}
      : "${psecs:=99}"

      if [ "$psecs" -ge 12 ]; then
        echo "not yet: with the application stalled, /health took ${ptime}s, and the"
        echo "         requirement is under ten."
        echo "         nginx waits 60s by default, and the deadline a websocket needs is"
        echo "         longer still. A socket that is idle by design and a backend that"
        echo "         has wedged look identical to a timeout, so the two routes need"
        echo "         two deadlines — a short one here, a long one on the socket."
        exit 1
      fi

      # ---- naming it --------------------------------------------------------
      if [ ! -s /root/answers/ws.md ]; then
        echo "not yet: /root/answers/ws.md is missing or empty."
        exit 1
      fi

      low=$(tr 'A-Z' 'a-z' < /root/answers/ws.md)
      hc=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*handshake_code[[:space:]]*[:=][[:space:]]*\([0-9]*\).*/\1/p' | head -1)
      il=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*idle_limit_seconds[[:space:]]*[:=][[:space:]]*\([0-9]*\).*/\1/p' | head -1)

      if [ -z "$hc" ] || [ -z "$il" ]; then
        echo "not yet: /root/answers/ws.md needs a handshake_code line and an"
        echo "         idle_limit_seconds line."
        exit 1
      fi

      fail=0

      if [ "$hc" != "426" ]; then
        fail=1
        echo "not yet: you said handshake_code=$hc."
        case "$hc" in
          101)
            echo "         101 is what a successful upgrade returns. The question is what"
            echo "         came back when it was not working."
            ;;
          200)
            echo "         The application answers 200 on its ordinary routes. On /ws"
            echo "         without the upgrade headers it says something more specific."
            ;;
          *)
            echo "         Ask for it without the headers and read the status line:"
            echo "         curl -s -o /dev/null -w '%{http_code}\\n' http://172.32.0.11:8080/ws"
            ;;
        esac
      fi

      if [ "$il" != "60" ]; then
        fail=1
        echo "not yet: you said idle_limit_seconds=$il."
        case "$il" in
          300|3600)
            echo "         That is a value somebody chooses, not the one that was in"
            echo "         force. nginx's proxy_read_timeout has a default."
            ;;
          *)
            echo "         The socket died after a fixed interval of silence, and nothing"
            echo "         in the config set it. nginx's proxy_read_timeout defaults to"
            echo "         60s."
            ;;
        esac
      fi

      [ "$fail" -eq 0 ] || exit 1

      echo "PASS — the upgrade is forwarded, a socket idle for ninety seconds survives,"
      echo "       and an ordinary request against a stalled backend still gives up in"
      echo "       seconds."
