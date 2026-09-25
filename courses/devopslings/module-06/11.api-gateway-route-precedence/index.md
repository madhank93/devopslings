---
kind: lesson
title: "two routes match, and the gateway picks the other one"
description: |
  Reporting moved to its own service last month and the route was added to the
  gateway. Requests for it still land on the v2 API. The route is longer, more
  specific, and the person who added it has already tried moving it to the top
  of the file — which is the wrong thing to try, because this gateway does not
  read the file top to bottom.
name: api-gateway-route-precedence
slug: api-gateway-route-precedence
createdAt: "2026-09-25"

sandbox:
  stack: web-stack
  service: web

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      set -e

      systemctl stop haproxy.service nginx.service 2>/dev/null || true
      rm -f /etc/nginx/sites-enabled/* /etc/nginx/sites-available/gateway
      rm -f /etc/nginx/conf.d/*.conf /root/answers/gateway.md
      install -d /root/answers

      for p in 8081 8091; do
        curl -s -X POST -m 3 "http://172.32.0.11:$p/admin/reset" >/dev/null 2>&1 || true
      done
      ready=""
      for _ in $(seq 1 40); do
        if curl -s -m 2 http://172.32.0.11:8080/health 2>/dev/null | grep -q ok \
        && curl -s -m 2 http://172.32.0.11:8090/health 2>/dev/null | grep -q ok; then
          ready=yes
          break
        fi
        sleep 0.5
      done
      if [ -z "$ready" ]; then
        echo "the upstreams on 172.32.0.11:8080 and :8090 never came up"
        exit 1
      fi

      cat > /etc/nginx/conf.d/gateway-limits.conf <<'CONF'
      # Per client, not per gateway. Every route behind this gateway is public.
      limit_req_zone $binary_remote_addr zone=gw:10m rate=5r/s;
      limit_req_status 429;
      CONF

      cat > /etc/nginx/sites-available/gateway <<'CONF'
      upstream api     { server 172.32.0.11:8080; }   # users, orders, admin
      upstream reports { server 172.32.0.11:8090; }   # split out last month

      server {
          listen 80 default_server;
          server_name _;

          limit_req zone=gw burst=3 nodelay;

          # Reporting, moved to its own service. Added last month; already
          # tried at the top of this file, which changed nothing.
          location /api/v2/reports/ {
              rewrite ^/api/v2/reports/(.*)$ /reports/$1 break;
              proxy_pass http://reports;
          }

          # The v2 API. Written when v2 was the only thing under /api/v2/.
          location ~ ^/api/v2/(.*)$ {
              rewrite ^/api/v2/(.*)$ /v2/$1 break;
              proxy_pass http://api;
          }

          # v1, still serving clients we cannot upgrade.
          location /api/v1/ {
              rewrite ^/api/v1/(.*)$ /v1/$1 break;
              proxy_pass http://api;
          }

          # Admin. The gateway holds the token check, because the service
          # behind it has no idea who is calling.
          location /api/admin/ {
              if ($http_authorization != "Bearer s3cr3t") { return 401; }
              rewrite ^/api/admin/(.*)$ /admin/$1 break;
              proxy_pass http://api;
          }
      }
      CONF
      ln -sf /etc/nginx/sites-available/gateway /etc/nginx/sites-enabled/gateway

      if ! nginx -t 2>/tmp/nginx-t; then
        echo "the scenario's own nginx config did not load:"
        cat /tmp/nginx-t
        exit 1
      fi
      systemctl enable --now nginx.service >/dev/null 2>&1
      systemctl reload nginx.service 2>/dev/null || systemctl restart nginx.service
      for _ in $(seq 1 20); do
        curl -s -o /dev/null -m 2 http://127.0.0.1/api/v1/orders && break
        sleep 0.5
      done

      cat > /root/answers/gateway.md <<'MD'
      # The gateway

      # In the order the gateway applies them, what decides which route a
      # request takes? Name the steps, first to last.
      the-order: ?

      # One line: the reports route is longer and more specific than the v2
      # route, and it lost. Why?
      why-the-longer-route-lost: ?

      # One line: moving the reports block above the v2 block changed nothing.
      # What in this file is order-dependent, and what is not?
      what-order-affects: ?
      MD

      cat > /root/questions.txt <<'Q'
      Four services behind one gateway, on port 80 of this box:

        /api/v1/...            -> the legacy API      (172.32.0.11:8080)
        /api/v2/...            -> the v2 API          (172.32.0.11:8080)
        /api/v2/reports/...    -> the reports service (172.32.0.11:8090)
        /api/admin/...         -> the admin API, token required

      Reporting was split into its own service last month. Its requests still
      arrive at the v2 API:

        $ curl -s http://127.0.0.1/api/v2/reports/daily
        no route: /v2/reports/daily

        $ curl -s http://127.0.0.1/api/v2/orders
        v2 api: orders 1001 1002

      Each upstream records what it was actually asked for:

        $ curl -s http://172.32.0.11:8081/admin/received   # the API
        $ curl -s http://172.32.0.11:8091/admin/received   # reports

      The routes are in /etc/nginx/sites-available/gateway. Moving the reports
      block to the top of the file has already been tried.

      Whatever you change, the admin route must still refuse a request with no
      token, and the rate limiter must still count each client separately.

      Write your answers in /root/answers/gateway.md.
      Q

      echo "scenario ready"
      echo
      echo "  the gateway:  /etc/nginx/sites-available/gateway"
      echo "  the brief:    /root/questions.txt"
      echo "  your answer:  /root/answers/gateway.md"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      ans=/root/answers/gateway.md

      if [ ! -s "$ans" ]; then
        echo "not yet: $ans is missing or empty"
        exit 1
      fi
      if grep -q ': *?$' "$ans" 2>/dev/null; then
        echo "not yet: $ans still has unanswered '?' fields"
        exit 1
      fi
      if ! nginx -t 2>/tmp/nginx-t; then
        echo "not yet: nginx will not load the config:"
        sed 's/^/    /' /tmp/nginx-t
        exit 1
      fi
      # Restart rather than reload: a reload leaves the old workers serving until
      # their connections drain, and a check that measures which route a request
      # took cannot afford to race that.
      systemctl restart nginx.service
      for _ in $(seq 1 20); do
        curl -s -o /dev/null -m 2 http://127.0.0.1/api/v1/orders && break
        sleep 0.5
      done

      field() {
        grep -E "^$1:" "$ans" 2>/dev/null | head -1 | sed "s/^$1: *//" | tr -d '\r' || true
      }
      reset() {
        for p in 8081 8091; do
          curl -s -X POST -m 3 "http://172.32.0.11:$p/admin/reset" >/dev/null 2>&1 || true
        done
      }
      recv() { curl -s -m 3 "http://172.32.0.11:$1/admin/received" 2>/dev/null || true; }

      # --- each request at the service it was meant for -----------------------
      # A source address per route, so the four checks do not queue behind each
      # other in the rate limiter they are also being graded on.
      while read -r label iface req port want other; do
        reset
        code=$(curl -s -m 5 --interface "$iface" -o /tmp/gw-body -w '%{http_code}' \
                 -H 'Authorization: Bearer s3cr3t' "http://127.0.0.1$req" || true)
        got=$(recv "$port")
        if [ "$code" = "429" ]; then
          echo "not yet: $req was refused by the limiter (429) before it could be routed at"
          echo "all. Each of these four checks comes from a different client address and"
          echo "sends one request, so no client is over any per-client rate. They are"
          echo "sharing a bucket, and the key the zone is declared with is what decides"
          echo "whose bucket a request lands in."
          exit 1
        fi
        if ! printf '%s' "$got" | grep -qF "GET $want"; then
          echo "not yet: $req was meant for the $label service, and it did not arrive there."
          echo
          echo "    it answered $code: $(head -1 /tmp/gw-body 2>/dev/null)"
          echo "    the $label service was asked for: $(printf '%s' "$got" | tr '\n' ' ' | sed 's/ *$//')"
          echo "    the other one was asked for:      $(recv "$other" | tr '\n' ' ' | sed 's/ *$//')"
          echo
          echo "Two blocks in the gateway can serve this request. Which one nginx picks is"
          echo "not a question about the file — it is a question about what kind of match"
          echo "each block is. 'location' in the nginx documentation lists the kinds in the"
          echo "order they are tried."
          exit 1
        fi
        if [ "$code" != "200" ]; then
          echo "not yet: $req reached the $label service and came back $code:"
          echo "    $(head -1 /tmp/gw-body 2>/dev/null)"
          echo "The service answers 200 on the path it owns, so a non-200 here is the"
          echo "rewrite handing it a path it does not have."
          exit 1
        fi
      done <<'ROUTES'
      reports 127.0.0.10 /api/v2/reports/daily 8091 /reports/daily 8081
      v2      127.0.0.11 /api/v2/orders        8081 /v2/orders     8091
      legacy  127.0.0.12 /api/v1/orders        8081 /v1/orders     8091
      admin   127.0.0.13 /api/admin/users      8081 /admin/users   8091
      ROUTES

      # --- the admin route still refuses an untokened request -----------------
      reset
      code=$(curl -s -m 5 --interface 127.0.0.14 -o /dev/null -w '%{http_code}' \
               http://127.0.0.1/api/admin/users || true)
      if [ "$code" != "401" ]; then
        echo "not yet: /api/admin/users with no Authorization header answered $code, and it"
        echo "has to be 401. The gateway holds that check — the service behind it serves"
        echo "whatever it is handed."
        exit 1
      fi
      if printf '%s' "$(recv 8081)" | grep -qF "GET /admin/users"; then
        echo "not yet: the untokened request was refused, and it reached the admin service"
        echo "first. A 401 that the backend has already served is not a gate."
        exit 1
      fi

      # --- and the limiter still counts per client ----------------------------
      flood=""
      for _ in $(seq 1 12); do
        flood="$flood $(curl -s -m 5 --interface 127.0.0.20 -o /dev/null -w '%{http_code}' \
                          http://127.0.0.1/api/v1/orders || true)"
      done
      if ! printf '%s' "$flood" | grep -q 429; then
        echo "not yet: twelve requests in a row from one client were all served:"
        echo "   $flood"
        echo "The zone is 5r/s with a burst of 3, so a client sending twelve as fast as it"
        echo "can has to be refused some of them."
        exit 1
      fi
      # The second client's bucket has to be full when it starts, or a re-run of
      # this check inherits what the previous one spent. 5r/s refills a burst of
      # three in well under a second.
      sleep 2
      quiet=""
      for _ in $(seq 1 3); do
        quiet="$quiet $(curl -s -m 5 --interface 127.0.0.21 -o /dev/null -w '%{http_code}' \
                          http://127.0.0.1/api/v1/orders || true)"
      done
      if printf '%s' "$quiet" | grep -q 429; then
        echo "not yet: a second client sent three requests and was refused:"
        echo "   $quiet"
        echo "It is being counted in the same bucket as the client that just sent twelve."
        echo "The key the zone is declared with is what decides whose bucket a request"
        echo "lands in."
        exit 1
      fi

      # --- the reasons --------------------------------------------------------
      order=$(field the-order | tr 'A-Z' 'a-z')
      if ! printf '%s' "$order" | grep -Eq '\b(host|server_?name|virtual host|vhost)\b'; then
        echo "not yet: 'the-order:' does not start where nginx starts. Before any location is"
        echo "considered, one thing about the request picks the server block. Name it first."
        exit 1
      fi
      if ! printf '%s' "$order" | grep -Eq '\b(path|paths|uri|location|locations|prefix|regex)\b'; then
        echo "not yet: 'the-order:' does not say what is matched after the server block is"
        echo "chosen. Name the part of the request the location blocks are tested against,"
        echo "and the kinds of match nginx tries in turn."
        exit 1
      fi
      if ! printf '%s' "$order" | grep -Eq '\b(method|methods|header|headers|verb)\b'; then
        echo "not yet: 'the-order:' stops too early. The route is chosen before anything"
        echo "looks at how the request was made — say where the method and the headers come"
        echo "in, and what that means for a rule that depends on one."
        exit 1
      fi
      lost=$(field why-the-longer-route-lost | tr 'A-Z' 'a-z')
      if ! printf '%s' "$lost" | grep -Eq '(regex|regexp|regular expression|~)'; then
        echo "not yet: 'why-the-longer-route-lost:' does not say what the winning block was."
        echo "The two blocks are not the same kind of location. Look at the character in"
        echo "front of the v2 pattern and what it makes that block."
        exit 1
      fi
      if ! printf '%s' "$lost" | grep -Eq '\b(before|beat|beats|wins|won|first|precedence|priority|ahead|over|unless|\^~)\b'; then
        echo "not yet: 'why-the-longer-route-lost:' names the kinds and not the rule between"
        echo "them. Say which kind nginx tries first, and what the longer plain prefix would"
        echo "have needed to win."
        exit 1
      fi
      what=$(field what-order-affects | tr 'A-Z' 'a-z')
      if ! printf '%s' "$what" | grep -Eq '(regex|regexp|regular expression)'; then
        echo "not yet: 'what-order-affects:' does not name the one kind of location where"
        echo "the order in the file is the whole answer. Two of them in a file are tried"
        echo "top to bottom; everything else is decided without reading the file in order."
        exit 1
      fi

      echo "PASS — four requests at four services, the admin route still refused without a"
      echo "token, and the second client not paying for the first one's flood."
