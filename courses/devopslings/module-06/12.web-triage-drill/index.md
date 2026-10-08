---
kind: lesson
title: "some requests to the shop fail or hang since last night's deploy"
description: |
  Since last night's deploy some requests to the shop fail or hang. That is the
  whole ticket, every time — because the fault is drawn at random from five,
  each a different seam in the proxy: a prefix that is no longer stripped, a
  deadline shorter than the route it guards, a cache key that forgot the query
  string, a body limit back at its default, and an upgrade that never reaches
  the application. The drill is the order you ask the next hop questions in.
name: web-triage-drill
slug: web-triage-drill
createdAt: "2026-10-07"
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
      systemctl stop nginx.service haproxy.service caddy-site.service caddy-ca.service waf.service 2>/dev/null || true
      rm -f /etc/nginx/sites-enabled/* /etc/nginx/sites-available/shop
      rm -f /etc/nginx/conf.d/*.conf
      rm -rf /var/cache/nginx/shop /var/lib/drill /etc/shop /var/lib/shop
      rm -f /root/answers/triage.md /usr/local/bin/shop-smoke
      install -d -o www-data -g www-data /var/cache/nginx
      install -d /root/answers /var/lib/drill /etc/shop /var/lib/shop

      # Both backends back to their defaults, then reports put back to the
      # five seconds it takes by design.
      for port in 8081 8091; do
        curl -s -X POST -m 3 "http://172.32.0.11:$port/admin/reset" >/dev/null 2>&1 || true
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
      curl -s -X POST -m 3 'http://172.32.0.11:8091/admin/mode?value=slow&ms=5000' >/dev/null

      # ---- the gateway, as it should be ----------------------------------
      cat > /etc/nginx/conf.d/shop.conf <<'CONF'
      limit_req_zone $binary_remote_addr zone=perclient:10m rate=5r/s;
      limit_req_status 429;

      proxy_cache_path /var/cache/nginx/shop levels=1:2 keys_zone=shop:10m
                       max_size=100m inactive=1d;
      CONF

      cat > /etc/nginx/sites-available/shop <<'CONF'
      # The shop's gateway. Shop API and assets on 172.32.0.11:8080, reports on
      # 172.32.0.11:8090.
      server {
          listen 80 default_server;
          server_name _;

          proxy_connect_timeout 3s;
          proxy_read_timeout 3s;

          location /api/ {
              # Added after the scraper on 172.32.0.12. Per client.
              limit_req zone=perclient burst=10 nodelay;
              proxy_pass http://172.32.0.11:8080/;
          }

          location /reports/ {
              proxy_read_timeout 15s;
              proxy_pass http://172.32.0.11:8090;
          }

          # Fingerprinted: every deploy asks for it under a new ?v=, so a copy
          # can be kept for a day whatever the origin says.
          location = /asset.js {
              proxy_cache shop;
              proxy_cache_key "$scheme$request_method$host$request_uri";
              proxy_ignore_headers Cache-Control Expires;
              proxy_cache_valid 200 1d;
              add_header X-Cache-Status $upstream_cache_status always;
              proxy_pass http://172.32.0.11:8080;
          }

          location = /upload {
              client_max_body_size 20m;
              proxy_pass http://172.32.0.11:8080;
          }

          location = /ws {
              proxy_http_version 1.1;
              proxy_set_header Upgrade $http_upgrade;
              proxy_set_header Connection "upgrade";
              proxy_read_timeout 300s;
              proxy_pass http://172.32.0.11:8080;
          }
      }
      CONF
      ln -sf /etc/nginx/sites-available/shop /etc/nginx/sites-enabled/shop

      # ---- one customer visit, as a script --------------------------------
      head -c 5242880 /dev/zero > /var/lib/shop/basket-5m.bin
      cat > /usr/local/bin/shop-smoke <<'SMOKE'
      #!/bin/bash
      # One customer visit through the gateway on 127.0.0.1, a line per step:
      # the step, then the status and the time it took.
      build=$(cat /etc/shop/release 2>/dev/null || echo 1)
      body=$(mktemp)
      fail=0
      step() {
        label=$1 want=$2
        shift 2
        meta=$(curl -s -m 20 -o "$body" -w '%{http_code} %{time_total}s' "$@" 2>/dev/null || true)
        if [ "$(cat "$body" 2>/dev/null)" = "$want" ]; then r=ok; else r=FAIL; fail=1; fi
        printf '%-5s %-30s %s\n' "$r" "$label" "${meta:-000}"
      }
      step "GET  /api/users"          'users: alice bob carol' http://127.0.0.1/api/users
      step "GET  /api/orders"         'orders: 1001 1002'      http://127.0.0.1/api/orders
      step "GET  /reports/daily"      'reports: daily rollup'  http://127.0.0.1/reports/daily
      step "GET  /asset.js?v=$build"  "console.log('build $build');" "http://127.0.0.1/asset.js?v=$build"
      step "POST /upload (5 MB)"      'stored bytes=5242880' --data-binary @/var/lib/shop/basket-5m.bin http://127.0.0.1/upload
      ws=$(wsprobe http://127.0.0.1/ws --idle 1 --timeout 10 2>&1 || true)
      case "$ws" in ok:*) r=ok ;; *) r=FAIL; fail=1 ;; esac
      printf '%-5s %-30s %s\n' "$r" "WS   /ws" "$ws"
      rm -f "$body"
      exit "$fail"
      SMOKE
      chmod 0755 /usr/local/bin/shop-smoke

      # ---- the red herring ------------------------------------------------
      #
      # Last night's access log: a scraper on 172.32.0.12 refused thousands of
      # times by the limiter, around ordinary customers being served. It looks
      # like "requests failing since last night", and it is the limiter working.
      python3 - <<'PY'
      import random
      random.seed(6)
      ua = '"Mozilla/5.0 (X11; Linux x86_64)"'
      with open("/var/log/nginx/access.log.1", "w") as f:
          for n in range(24000):
              h, m, s = 22 + n // 7200, (n // 120) % 60, (n // 2) % 60
              h %= 24
              ts = f"06/Oct/2026:{h:02d}:{m:02d}:{s:02d} +0000"
              if n % 4:
                  path = random.choice(["/api/orders", "/api/users"])
                  f.write(f'172.32.0.12 - - [{ts}] "GET {path}?page={n} HTTP/1.1" 429 162 "-" "scrapy/2.11"\n')
              else:
                  ip = f"10.4.{random.randint(0, 9)}.{random.randint(2, 250)}"
                  path = random.choice(["/api/users", "/api/orders", "/asset.js?v=1", "/reports/daily"])
                  f.write(f'{ip} - - [{ts}] "GET {path} HTTP/1.1" 200 {random.randint(20, 900)} "-" {ua}\n')
      PY
      chown www-data:adm /var/log/nginx/access.log.1
      chmod 0640 /var/log/nginx/access.log.1
      touch -d '-8 hours' /var/log/nginx/access.log.1
      sha256sum /var/log/nginx/access.log.1 | awk '{print $1}' > /var/lib/drill/herring

      # ---- prove it healthy before breaking one thing ---------------------
      printf '1\n' > /etc/shop/release
      if ! nginx -t 2>/root/nginx-t; then
        echo "the scenario's own nginx config did not load:"
        cat /root/nginx-t
        exit 1
      fi
      rm -f /root/nginx-t
      systemctl enable --now nginx.service >/dev/null 2>&1
      systemctl restart nginx.service
      for _ in $(seq 1 20); do
        curl -s -o /dev/null -m 2 http://127.0.0.1/api/users && break
        sleep 0.5
      done
      if ! out=$(shop-smoke 2>&1); then
        echo "the scenario did not come up healthy before the fault was seeded:"
        echo "$out"
        exit 1
      fi

      # ---- seed one fault --------------------------------------------------
      faults="slash timeout cache body upgrade"
      n=$(od -An -N2 -tu2 < /dev/urandom | tr -d ' ')
      fault=$(echo "$faults" | cut -d' ' -f$(( n % 5 + 1 )))

      conf=/etc/nginx/sites-available/shop
      case "$fault" in
        slash)
          # The URI part of proxy_pass dropped: /api/users is forwarded whole.
          sed -i 's#proxy_pass http://172.32.0.11:8080/;#proxy_pass http://172.32.0.11:8080;#' "$conf" ;;
        timeout)
          # The reports route lost its own deadline and inherits the 3s one.
          sed -i '/proxy_read_timeout 15s;/d' "$conf" ;;
        cache)
          # $uri stops at the '?', so every ?v= is the same cache entry.
          sed -i 's/\$host\$request_uri"/$host$uri"/' "$conf" ;;
        body)
          # The upload limit gone, and nginx's default is 1m.
          sed -i '/client_max_body_size 20m;/d' "$conf" ;;
        upgrade)
          # Upgrade and Connection are hop-by-hop: not forwarded unless set.
          sed -i '/proxy_set_header Upgrade/d; /proxy_set_header Connection/d' "$conf" ;;
      esac
      nginx -t >/dev/null 2>&1
      systemctl reload nginx.service
      sleep 1

      # Yesterday's build is in the edge cache under yesterday's URL, then
      # tonight's build goes out.
      curl -s -o /dev/null -m 5 'http://127.0.0.1/asset.js?v=1' || true
      curl -s -X POST -m 3 'http://172.32.0.11:8081/admin/reset' >/dev/null 2>&1 || true
      curl -s -X POST -m 3 'http://172.32.0.11:8091/admin/reset' >/dev/null 2>&1 || true
      curl -s -X POST -m 3 'http://172.32.0.11:8091/admin/mode?value=slow&ms=5000' >/dev/null
      curl -s -X POST -m 3 'http://172.32.0.11:8081/admin/deploy?version=2' >/dev/null
      printf '2\n' > /etc/shop/release
      truncate -s 0 /var/log/nginx/error.log /var/log/nginx/access.log 2>/dev/null || true

      # One visit after the deploy, so the evidence is already in the logs and
      # in each upstream's record when the student arrives.
      if shop-smoke >/dev/null 2>&1; then
        echo "the $fault fault was seeded and the shop still works"
        exit 1
      fi

      # The digest, not the name: obfuscation, not a secret. The real gate is
      # the shop working again, repaired at the cause.
      printf '%s' "$fault" | sha256sum | awk '{print $1}' > /var/lib/drill/state
      chmod 600 /var/lib/drill/state /var/lib/drill/herring

      cat > /root/questions.txt <<'Q'
      Since last night's deploy, some requests to the shop fail or hang.

      shop-smoke walks one customer visit through the gateway on this box and
      prints a line per step:

        $ shop-smoke

      Everything worked before the deploy, and exactly one thing in it is
      wrong — drawn at random from five.

      The gateway is nginx: /etc/nginx/sites-available/shop and
      /etc/nginx/conf.d/shop.conf, logs in /var/log/nginx. Behind it, on
      172.32.0.11, are two services that are not yours:

        shop API, assets, uploads, websocket  ->  :8080   (admin API :8081)
        reports                               ->  :8090   (admin API :8091)

      Each admin API says what that service was actually asked for:

        curl -s http://172.32.0.11:8081/admin/received
        curl -s http://172.32.0.11:8081/admin/last

      Reports take five seconds to build. That is by design, and it will be
      put back to five seconds when you are graded.

      1. Make shop-smoke pass by repairing the gateway where the deploy broke
         it. Not around it: every other route keeps the deadlines, limits and
         caching it has.

      2. Write /root/answers/triage.md, three lines:

           cause:     <what was wrong, in a few words>
           evidence:  <the command or log line that proved it>
           detection: <a signal and a threshold that would have paged first>

      Run it again and the fault moves. The drill is the order of the
      questions, not the answer.
      Q

      echo "scenario ready — one fault seeded, shop-smoke failing"

  inject_fault:
    timeout_seconds: 60
    run: |
      # Reports are slow by design and the shop API is not; both are put back
      # before grading, so a fix that only worked because a backend changed
      # speed is graded as what it is.
      curl -s -X POST -m 5 'http://172.32.0.11:8091/admin/mode?value=slow&ms=5000' >/dev/null 2>&1
      curl -s -X POST -m 5 'http://172.32.0.11:8081/admin/mode?value=normal' >/dev/null 2>&1
      echo "reports at five seconds, shop API at full speed"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      conf=/etc/nginx/sites-available/shop
      admin=http://172.32.0.11:8081
      digest=$(cat /var/lib/drill/state 2>/dev/null || true)
      fault=""
      for cand in slash timeout cache body upgrade; do
        [ "$(printf '%s' "$cand" | sha256sum | awk '{print $1}')" = "$digest" ] && fault=$cand
      done
      if [ -z "$fault" ]; then
        echo "not yet: /var/lib/drill/state does not name a seeded fault."
        echo "         Start the lesson again — the scenario has to seed one before"
        echo "         it can be graded."
        exit 1
      fi

      # The checks below stall the shop API and deploy builds on purpose. Put
      # both back on every exit path.
      release=$(tr -dc '0-9' < /etc/shop/release 2>/dev/null || true)
      restore() {
        curl -s -X POST -m 5 "$admin/admin/mode?value=normal" >/dev/null 2>&1 || true
        curl -s -X POST -m 5 "$admin/admin/deploy?version=${release:-2}" >/dev/null 2>&1 || true
      }
      trap restore EXIT
      tmp=$(mktemp -d)

      if ! nginx -t >/dev/null 2>&1; then
        echo "not yet: nginx will not load the config:"
        nginx -t 2>&1 | sed 's/^/         /' || true
        exit 1
      fi
      if ! systemctl is-active --quiet nginx.service; then
        echo "not yet: nginx is not running. systemctl status nginx says why."
        exit 1
      fi

      get() {
        meta=$(curl -s -m "$1" -o "$tmp/body" -D "$tmp/head" -w '%{http_code} %{time_total}' "${@:2}" 2>/dev/null || true)
        code=${meta%% *}
        secs=${meta##* }
        : "${code:=000}" "${secs:=0}"
        body=$(cat "$tmp/body" 2>/dev/null || true)
        who=$(grep -i '^x-upstream:' "$tmp/head" 2>/dev/null | tr -d '\r' | awk '{print $2}' || true)
      }

      # ---- the shop API ----------------------------------------------------
      for route in users:'users: alice bob carol' orders:'orders: 1001 1002'; do
        p=${route%%:*}
        want=${route#*:}
        get 10 "http://127.0.0.1/api/$p"
        if [ "$body" != "$want" ]; then
          echo "not yet: /api/$p answered $code: $(printf '%s' "$body" | head -1)"
          case "$code:$body" in
            "404:no route:"*)
              echo "         That 404 is the shop API's own, so the request arrived and the"
              echo "         path was wrong. It records exactly what it was asked for:"
              echo "         curl -s $admin/admin/received"
              ;;
            429:*)
              echo "         The limiter refused it before it was proxied. One request from"
              echo "         127.0.0.1 is not a flood."
              ;;
            200:*)
              echo "         Expected: $want. X-Upstream said '${who:-nothing}' — the shop API"
              echo "         sets it to 'a' on everything it answers."
              ;;
            5*)
              echo "         The gateway could not get an answer from 172.32.0.11:8080."
              echo "         /var/log/nginx/error.log has a line for it."
              ;;
          esac
          exit 1
        fi
      done

      # Answered by the upstream, under the path it owns. A body served from
      # nginx passes the check above and proxies nothing.
      token="p$(od -An -N3 -tu4 < /dev/urandom | tr -d ' ')"
      get 10 "http://127.0.0.1/api/users?probe=$token"
      seen=$(curl -s -m 5 "$admin/admin/received" 2>/dev/null | grep -F "$token" | tail -1 || true)
      if [ "$seen" != "GET /users?probe=$token" ]; then
        echo "not yet: /api/users?probe=$token should reach the shop API as"
        echo "         'GET /users?probe=$token'. It recorded: '${seen:-nothing}'."
        exit 1
      fi
      if grep -qE '(^|[[:space:]]|\{)rewrite[[:space:]]' "$conf" 2>/dev/null; then
        echo "not yet: there is a rewrite directive in $conf. proxy_pass already"
        echo "         replaces the prefix a location matched, when it has a URI part"
        echo "         after the host; a second mechanism doing the same job is the"
        echo "         next deploy's bug."
        exit 1
      fi

      # ---- reports -----------------------------------------------------------
      get 30 http://127.0.0.1/reports/daily
      if [ "$body" != "reports: daily rollup" ]; then
        echo "not yet: /reports/daily answered $code after ${secs}s."
        case "$code" in
          504)
            echo "         504 is the gateway's own deadline running out, not an error"
            echo "         from the reports service. error.log names the deadline; ask the"
            echo "         service directly how long it takes:"
            echo "         curl -s -o /dev/null -w '%{time_total}\\n' http://172.32.0.11:8090/reports/daily"
            ;;
          502)
            echo "         502 is the gateway getting no response at all from the reports"
            echo "         service. error.log says whether it was refused or cut off."
            ;;
        esac
        exit 1
      fi
      if [ "$who" != b ] || [ "${secs%%.*}" -lt 4 ]; then
        echo "not yet: /reports/daily answered in ${secs}s from '${who:-nothing}', and the"
        echo "         reports service on :8090 takes five seconds. Something else built it."
        exit 1
      fi

      # ---- the asset, across a deploy ----------------------------------------
      old=$(( (RANDOM % 400) + 100 ))
      new=$(( old + 1 ))
      curl -s -X POST -m 5 "$admin/admin/deploy?version=$old" >/dev/null 2>&1 || true
      get 10 "http://127.0.0.1/asset.js?v=$old"
      curl -s -X POST -m 5 "$admin/admin/deploy?version=$new" >/dev/null 2>&1 || true
      get 10 "http://127.0.0.1/asset.js?v=$new"
      if [ "$body" != "console.log('build $new');" ]; then
        cs=$(grep -i '^x-cache-status:' "$tmp/head" 2>/dev/null | tr -d '\r' | awk '{print $2}' || true)
        echo "not yet: build $new was deployed and /asset.js?v=$new, a URL nobody had"
        echo "         asked for before, served: $(printf '%s' "$body" | head -1)"
        echo "         X-Cache-Status said '${cs:-nothing}'."
        if [ "$cs" = HIT ]; then
          echo "         A hit on a URL never seen before means the cache key does not"
          echo "         contain the part of the URL that changed. \$uri stops at the '?'."
        fi
        exit 1
      fi

      # ---- uploads -------------------------------------------------------------
      head -c 5242880 /dev/zero > "$tmp/5m"
      get 60 --data-binary @"$tmp/5m" http://127.0.0.1/upload
      if [ "$body" != "stored bytes=5242880" ]; then
        echo "not yet: a 5 MB upload answered $code."
        if [ "$code" = 413 ]; then
          echo "         Ask the shop API whether it ever saw it ($admin/admin/received),"
          echo "         and read the 413's own body. error.log says how large the body"
          echo "         was and that the gateway would not take it."
        fi
        exit 1
      fi

      # ---- the websocket -------------------------------------------------------
      ws=$(wsprobe http://127.0.0.1/ws --idle 1 --timeout 10 2>&1 || true)
      case "$ws" in
        ok:*) ;;
        *)
          echo "not yet: wsprobe through the gateway said: $ws"
          case "$ws" in
            *426*)
              echo "         426 comes from the shop API: the handshake reached it without"
              echo "         the headers that make it one. $admin/admin/last shows what it"
              echo "         was handed. Upgrade and Connection are hop-by-hop, and a proxy"
              echo "         does not pass them on unless it is told to."
              ;;
          esac
          exit 1
          ;;
      esac

      # ---- every other route kept what it had -----------------------------------
      #
      # The shop API stalled: ordinary requests still give up at the gateway's
      # short deadline. A read timeout raised for the whole server fixes reports
      # and takes this with it.
      curl -s -X POST -m 5 "$admin/admin/mode?value=slow&ms=10000" >/dev/null 2>&1 || true
      get 30 http://127.0.0.1/api/orders
      curl -s -X POST -m 5 "$admin/admin/mode?value=normal" >/dev/null 2>&1 || true
      if [ "${secs%%.*}" -ge 5 ]; then
        echo "not yet: with the shop API stalled, /api/orders waited ${secs}s before giving"
        echo "         up ($code). It used to give up in three. The read timeout went up"
        echo "         for everything rather than for the one route that needs it, and"
        echo "         every worker held by a stalled backend serves nothing else."
        exit 1
      fi

      head -c 67108864 /dev/zero > "$tmp/64m"
      code=$(curl -s -o /dev/null -m 120 -w '%{http_code}' --data-binary @"$tmp/64m" http://127.0.0.1/upload 2>/dev/null || true)
      rm -f "$tmp/64m"
      if [ "$code" != 413 ]; then
        echo "not yet: a 64 MB upload answered ${code:-nothing}, and it has to be refused with"
        echo "         413. The limit was 20m; a bigger one, or 0 for none, lets every body"
        echo "         be as large as the client likes."
        exit 1
      fi

      # Ten requests for one asset over five seconds, against a cleared record:
      # a cache sends the origin at most one or two of them.
      curl -s -X POST -m 5 "$admin/admin/reset" >/dev/null 2>&1 || true
      curl -s -X POST -m 5 "$admin/admin/deploy?version=$new" >/dev/null 2>&1 || true
      for _ in $(seq 1 10); do
        curl -s -o /dev/null -m 8 "http://127.0.0.1/asset.js?v=$new" 2>/dev/null || true
        sleep 0.5
      done
      hits=$(curl -s -m 5 "$admin/admin/received" 2>/dev/null | grep -c 'asset.js' || true)
      : "${hits:=0}"
      if [ "$hits" -gt 2 ]; then
        echo "not yet: ten requests for one asset reached the origin $hits times."
        echo "         The edge has to stay a cache. Caching turned off, a validity of"
        echo "         seconds, or a key with something unique in it serve the right"
        echo "         build and hand the origin all the traffic."
        exit 1
      fi

      # ---- the red herring --------------------------------------------------
      sleep 3
      flood=""
      for _ in $(seq 1 20); do
        flood="$flood $(curl -s -o /dev/null -m 5 -w '%{http_code}' --interface 127.0.0.20 http://127.0.0.1/api/orders 2>/dev/null || true)"
      done
      if ! printf '%s' "$flood" | grep -q 429; then
        echo "not yet: twenty requests in a row from one client were all served:"
        echo "        $flood"
        echo "         The limiter on /api/ was removed or raised. The 429s in"
        echo "         access.log.1 were a scraper on 172.32.0.12 being refused, which"
        echo "         is the limiter doing its job; they were never the fault."
        exit 1
      fi
      quiet=""
      for _ in $(seq 1 3); do
        quiet="$quiet $(curl -s -o /dev/null -m 5 -w '%{http_code}' --interface 127.0.0.21 http://127.0.0.1/api/orders 2>/dev/null || true)"
      done
      if printf '%s' "$quiet" | grep -q 429; then
        echo "not yet: a second client sent three requests and was refused:$quiet"
        echo "         It is sharing a bucket with the one that just flooded. The key the"
        echo "         zone is declared with decides whose bucket a request lands in."
        exit 1
      fi
      if [ "$(sha256sum /var/log/nginx/access.log.1 2>/dev/null | awk '{print $1}')" != "$(cat /var/lib/drill/herring)" ]; then
        echo "not yet: /var/log/nginx/access.log.1 is gone or changed. It was last"
        echo "         night's log, and its 429s were the limiter refusing a scraper."
        echo "         It was evidence, never the fault; put it back as it was."
        exit 1
      fi

      # ---- naming it --------------------------------------------------------
      if [ ! -s /root/answers/triage.md ]; then
        echo "not yet: /root/answers/triage.md is missing or empty. Three lines:"
        echo "         cause, evidence, detection."
        exit 1
      fi
      low=$(tr 'A-Z' 'a-z' < /root/answers/triage.md)
      field() { printf '%s\n' "$low" | sed -n "s/^[[:space:]]*$1[[:space:]]*[:=][[:space:]]*//p" | awk 'NR==1'; }
      a_cause=$(field cause); a_ev=$(field evidence); a_det=$(field detection)

      case "$fault" in
        slash)
          what="proxy_pass on /api/ lost its trailing slash, so the shop API was asked for /api/users instead of /users"
          c_re='\b(slash|trailing|prefix|proxy_pass|strip|stripped|uri)\b'
          e_re='admin/received|admin/last|\bno route\b|x-upstream'
          e_say="the shop API's own record (curl :8081/admin/received) showing GET /api/users, or its 'no route' 404"
          d_re='\b(404s?|4xx|errors?|error rate|synthetic|smoke|probe|status)\b'
          d_say="404s from the upstream on /api/, or a synthetic check of the route" ;;
        timeout)
          what="the reports route lost its proxy_read_timeout 15s and inherited the server's 3s, shorter than the five seconds a report takes"
          c_re='\b(timeouts?|timed out|proxy_read_timeout|deadline|504s?)\b'
          e_re='\btimed out\b|error\.log|time_total|8090'
          e_say="error.log's 'upstream timed out ... while reading response header', or timing the reports service directly on :8090"
          d_re='\b(504s?|5xx|latency|p95|p99|upstream_response_time|request_time|duration|timeouts?)\b'
          d_say="504s on /reports/, or upstream response time against the route's deadline" ;;
        cache)
          what="the asset cache key used \$uri, which stops at the '?', so every ?v= was served yesterday's cached build"
          c_re='\b(key|cache_key|proxy_cache_key|query|querystring|args|request_uri|uri)\b'
          e_re='x-cache|\bhit\b|admin/received|upstream_cache_status'
          e_say="X-Cache-Status: HIT on a URL never requested before, with no request for it in the origin's /admin/received"
          d_re='\b(build|version|deploy|deployed|mismatch|synthetic|smoke|probe|canary|checksum|hash)\b'
          d_say="a synthetic check comparing the build served at the edge with the build deployed" ;;
        body)
          what="client_max_body_size 20m was dropped from /upload, so nginx's 1m default refused the 5 MB basket with 413"
          c_re='\b(client_max_body_size|body|size|413|too large|limit|1m)\b'
          e_re='client intended|too large|error\.log|admin/received|\bnginx\b'
          e_say="error.log's 'client intended to send too large body', or no record of the upload in the shop API's /admin/received"
          d_re='\b(413s?|4xx|uploads?|body|size|errors?|error rate|synthetic|smoke)\b'
          d_say="413s on /upload, as a rate" ;;
        upgrade)
          what="the /ws location stopped forwarding Upgrade and Connection, so the shop API got a plain GET and answered 426"
          c_re='\b(upgrade|websockets?|connection|hop-by-hop)\b'
          e_re='\b426\b|wsprobe|admin/last|upgrade required|expected a websocket'
          e_say="wsprobe's 426, or the shop API's /admin/last showing the handshake arrived without Upgrade"
          d_re='\b(websockets?|ws|426|handshakes?|connections?|101|synthetic|probe|smoke)\b'
          d_say="failed websocket handshakes (426s, or 101s dropping)" ;;
      esac

      fail=0
      if [ -z "$a_cause" ] || ! printf '%s' "$a_cause" | grep -Eq "$c_re"; then
        fail=1
        echo "not yet: cause says '${a_cause:-nothing}', and the shop works, so something"
        echo "         was repaired. What was seeded:"
        echo "         $what."
      fi
      if [ -z "$a_ev" ] || ! printf '%s' "$a_ev" | grep -Eq "$e_re"; then
        fail=1
        echo "not yet: evidence says '${a_ev:-nothing}'. For this fault the proof is"
        echo "         $e_say."
      fi
      if [ -z "$a_det" ] || ! printf '%s' "$a_det" | grep -Eq "$d_re"; then
        fail=1
        echo "not yet: detection says '${a_det:-nothing}'. Name a signal that would have"
        echo "         paged before customers did: $d_say."
      elif ! printf '%s' "$a_det" | grep -q '[0-9]'; then
        fail=1
        echo "not yet: detection names a signal and no threshold. Say at what number"
        echo "         it pages — '504s > 1% for 5 minutes', with the number."
      fi
      [ "$fail" -eq 0 ] || exit 1

      echo "PASS — the seeded fault ($fault) was repaired at its cause, every other route"
      echo "       kept its deadline, limit and cache, the limiter still refuses a"
      echo "       flood per client, and triage.md names it."
---
