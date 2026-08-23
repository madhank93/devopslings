---
kind: lesson
title: "one client floods the API and everyone gets rate limited"
description: |
  The rate limiter is working exactly as configured, which is the problem: every
  request arrives from the proxy in front of it, so the whole internet shares one
  bucket. Fixing that by believing X-Forwarded-For is how you get a limiter that
  anybody can walk straight past.
name: real-ip-and-rate-limits
slug: real-ip-and-rate-limits
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
      rm -f /etc/nginx/sites-enabled/* /etc/nginx/sites-available/tiers
      rm -f /etc/nginx/conf.d/*.conf /root/answers/realip.md
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

      # ---- two tiers, as in front of any real API ------------------------
      #
      # The edge terminates the client connection and forwards, appending the
      # client's address to X-Forwarded-For. The limiter sits behind it and
      # counts by $binary_remote_addr — which, from where it stands, is the
      # edge. Every client on earth is one key.
      cat > /etc/nginx/conf.d/limits.conf <<'CONF'
      limit_req_zone $binary_remote_addr zone=perip:10m rate=5r/s;
      limit_req_status 429;
      CONF

      cat > /etc/nginx/sites-available/tiers <<'CONF'
      # the rate limiter, reachable only from this box
      server {
          listen 127.0.0.1:8081;

          location / {
              limit_req zone=perip burst=2 nodelay;
              proxy_pass http://172.32.0.11:8080;
              add_header X-Limiter-Saw $remote_addr always;
          }
      }

      # the edge, where clients arrive
      server {
          listen 80 default_server;
          server_name _;

          location / {
              proxy_pass http://127.0.0.1:8081;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          }
      }
      CONF
      ln -sf /etc/nginx/sites-available/tiers /etc/nginx/sites-enabled/tiers

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
      One client has been hammering the API since this morning, and support says
      everybody is getting 429s.

      Clients are simulated here by source address — 127.0.0.2, 127.0.0.3 and so
      on are different customers, and they all reach the edge at 127.0.0.1:80:

        $ for i in $(seq 1 8); do
            curl -s --interface 127.0.0.2 -o /dev/null -w '%{http_code} ' http://127.0.0.1/health
          done
        200 200 200 429 429 429 429 429

        $ for i in $(seq 1 3); do
            curl -s --interface 127.0.0.3 -o /dev/null -w '%{http_code} ' http://127.0.0.1/health
          done
        429 429 429

      127.0.0.3 has sent three requests all day and is being refused because of
      what 127.0.0.2 did.

      The limiter reports which address it counted the request under:

        $ curl -s --interface 127.0.0.3 -o /dev/null -D - http://127.0.0.1/health \
            | grep -i x-limiter-saw

      Two nginx server blocks are in /etc/nginx/sites-available/tiers: the edge
      on port 80, and the limiter it forwards to on 127.0.0.1:8081. The zone is
      in /etc/nginx/conf.d/limits.conf. All of it is yours.

      Three requirements.

      1. Per-client limiting. A client that floods gets 429s; a client that has
         sent three requests does not, at the same moment.

      2. The limit still exists. A flood from one address must still be refused
         with 429 — raising the rate until nothing trips is not a fix.

      3. A client cannot exempt itself. Anyone can put whatever they like in
         X-Forwarded-For, including a different value on every request. That
         must not buy them a fresh bucket each time.

      Then write /root/answers/realip.md, exactly two lines:

        before_key: <address>
        xff_trust: <leftmost | rightmost-untrusted>

      before_key is the address every request was being counted under before
      your fix. xff_trust is which entry in an X-Forwarded-For chain a proxy may
      believe.
      Q

      echo "scenario ready — one bucket for the whole internet"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      edge=http://127.0.0.1/health

      burst() {
        codes=""
        for _ in $(seq 1 10); do
          c=$(curl -s -m 5 -o /dev/null -w '%{http_code}' --interface "$1" ${2:+-H "X-Forwarded-For: $2"} "$edge" 2>/dev/null || echo 000)
          codes="$codes $c"
        done
      }

      # A quiet client's worth of traffic: below the limit for one client, so
      # anything but 200s here is somebody else's flood being charged to them.
      few() {
        codes=""
        for _ in $(seq 1 3); do
          c=$(curl -s -m 5 -o /dev/null -w '%{http_code}' --interface "$1" "$edge" 2>/dev/null || echo 000)
          codes="$codes $c"
        done
      }

      spoofed_burst() {
        codes=""
        for i in $(seq 1 10); do
          c=$(curl -s -m 5 -o /dev/null -w '%{http_code}' --interface "$1" -H "X-Forwarded-For: 9.9.9.$i" "$edge" 2>/dev/null || echo 000)
          codes="$codes $c"
        done
      }

      has429() { printf '%s' "$codes" | grep -q 429; }
      clean()  { ! printf '%s' "$codes" | grep -qv '^\( 200\)*$'; }

      # ---- a flood must still be refused -----------------------------------
      sleep 2
      burst 127.0.0.2
      flood="$codes"
      if ! has429; then
        echo "not yet: ten rapid requests from one client were all accepted:"
        echo "         $flood"
        echo "         The limiter has been raised or removed rather than made to count"
        echo "         per client. The flood is still a flood."
        exit 1
      fi

      # ---- and a quiet client must not pay for it ---------------------------
      few 127.0.0.3
      if ! clean; then
        echo "not yet: while 127.0.0.2 was flooding, 127.0.0.3 got:"
        echo "         $codes"
        echo "         Those two are different customers. The limiter is counting them"
        echo "         as one, which means it is counting by an address they share —"
        echo "         the only address it can see is the one the edge connects from."
        echo "         X-Limiter-Saw on any response says which address that is."
        exit 1
      fi

      # ---- and nobody can hand themselves a fresh bucket --------------------
      sleep 2
      spoofed_burst 127.0.0.4
      if ! has429; then
        echo "not yet: a client sending a different X-Forwarded-For on every request"
        echo "         was never limited:"
        echo "         $codes"
        echo "         The header is written by whoever is talking to you. Believing all"
        echo "         of it turns the rate limiter into an opt-in. A proxy may only"
        echo "         believe the entries appended by proxies it trusts."
        exit 1
      fi

      # ---- the traffic still goes to the origin -----------------------------
      sleep 2
      who=$(curl -s -m 8 --interface 127.0.0.5 -o /dev/null -D - "$edge" 2>/dev/null | grep -i '^x-upstream:' | tr -d '\r' | awk '{print $2}' || true)
      if [ "$who" != "a" ]; then
        echo "not yet: a request through the edge was not answered by the origin"
        echo "         (X-Upstream said '${who:-nothing}')."
        echo "         Rate limiting correctly and serving nothing is not the goal."
        exit 1
      fi

      # ---- naming it --------------------------------------------------------
      if [ ! -s /root/answers/realip.md ]; then
        echo "not yet: /root/answers/realip.md is missing or empty."
        exit 1
      fi

      low=$(tr 'A-Z' 'a-z' < /root/answers/realip.md)
      bk=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*before_key[[:space:]]*[:=][[:space:]]*\([0-9a-f.:]*\).*/\1/p' | head -1)
      xt=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*xff_trust[[:space:]]*[:=][[:space:]]*\([a-z-]*\).*/\1/p' | head -1)

      if [ -z "$bk" ] || [ -z "$xt" ]; then
        echo "not yet: /root/answers/realip.md needs a before_key line and an"
        echo "         xff_trust line."
        exit 1
      fi

      fail=0

      if [ "$bk" != "127.0.0.1" ]; then
        fail=1
        echo "not yet: you said before_key=$bk."
        case "$bk" in
          127.0.0.2|127.0.0.3|127.0.0.4)
            echo "         That is one of the clients. The limiter could not see any of"
            echo "         them — it saw whatever address the edge connected from."
            ;;
          *)
            echo "         The limiter counted every request under the address it received"
            echo "         the connection from, which is the edge's own."
            ;;
        esac
      fi

      case "$xt" in
        rightmost-untrusted|rightmost|right) ;;
        leftmost|left)
          fail=1
          echo "not yet: you said xff_trust=$xt."
          echo "         The leftmost entry is the one the client wrote. It is the origin"
          echo "         of the chain only when the client is honest, and a rate limiter"
          echo "         exists precisely for the clients who are not."
          ;;
        *)
          fail=1
          echo "not yet: xff_trust=$xt is not one of leftmost or rightmost-untrusted."
          ;;
      esac

      [ "$fail" -eq 0 ] || exit 1

      echo "PASS — floods are refused per client, a quiet client is unaffected by a"
      echo "       noisy one, a forged X-Forwarded-For buys nothing, and the traffic"
      echo "       still reaches the origin."
