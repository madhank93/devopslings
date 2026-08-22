---
kind: lesson
title: "every path through the proxy is off by one segment"
description: |
  Four routes through nginx, four 404s from the upstream, and the upstream is
  healthy — it answers every one of those routes when you ask it directly. The
  difference between the request that leaves the client and the request the
  upstream reads is one character of configuration, in two different places.
name: trailing-slash-proxy-pass
slug: trailing-slash-proxy-pass
createdAt: "2026-08-22"

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
      rm -f /root/answers/proxy.md
      install -d /root/answers

      # Wait for the upstream box. It is a separate machine and this lesson is
      # meaningless until it answers.
      up=""
      for _ in $(seq 1 40); do
        if curl -s -m 2 http://172.32.0.11:8080/health 2>/dev/null | grep -q ok; then
          up=yes
          break
        fi
        sleep 0.5
      done
      if [ -z "$up" ]; then
        echo "the upstream on 172.32.0.11:8080 never came up"
        exit 1
      fi

      # ---- the gateway -------------------------------------------------
      #
      # Two proxy blocks, each wrong in one of the two ways this trap has.
      #
      # /api/ has a proxy_pass with no URI part, so nginx forwards the request
      # URI unchanged and the upstream is asked for /api/users. It has /users.
      #
      # /docs has a proxy_pass with a URI part, which replaces the *matched
      # prefix* — and the matched prefix here is "/docs" with no trailing slash,
      # so what is left over still begins with one.
      cat > /etc/nginx/sites-available/gateway <<'CONF'
      server {
          listen 80 default_server;
          server_name _;

          location /api/ {
              proxy_pass http://172.32.0.11:8080;
              proxy_set_header Host $host;
          }

          location /docs {
              proxy_pass http://172.32.0.11:8080/pages/;
              proxy_set_header Host $host;
          }
      }
      CONF
      ln -sf /etc/nginx/sites-available/gateway /etc/nginx/sites-enabled/gateway

      systemctl enable --now nginx.service >/dev/null 2>&1
      systemctl reload nginx.service 2>/dev/null || systemctl restart nginx.service

      for _ in $(seq 1 20); do
        curl -s -o /dev/null -m 2 http://127.0.0.1/api/users && break
        sleep 0.5
      done

      # ---- leave the evidence ------------------------------------------
      #
      # The upstream keeps the last 200 request lines exactly as it received
      # them. Reset it, then make each failing request once, so the record of
      # what actually arrived is already there when the student looks — and is
      # still there after they have fixed it.
      curl -s -X POST -m 3 'http://172.32.0.11:8081/admin/reset' >/dev/null 2>&1 || true
      for p in /api/users /api/orders /api/version /docs/intro; do
        curl -s -o /dev/null -m 3 "http://127.0.0.1$p" || true
      done

      cat > /root/questions.txt <<'Q'
      The gateway on this box proxies four routes to the application on
      172.32.0.11:8080. All four return 404, and the body of each 404 comes
      from the application rather than from nginx:

        $ curl -s http://127.0.0.1/api/users
        no route: /api/users

      The application is healthy, and it answers all four when it is asked
      directly:

        $ curl -s http://172.32.0.11:8080/users
        users: alice bob carol
        $ curl -s http://172.32.0.11:8080/pages/intro
        docs: introduction

      Its routes are /users, /orders, /version and /pages/intro. The gateway is
      /etc/nginx/sites-available/gateway.

      The application records every request line exactly as it received it,
      including the ones already made for you:

        $ curl -s http://172.32.0.11:8081/admin/received

      Read that before you change anything. The difference between what you
      sent and what arrived is the entire exercise.

      Two things to do.

      1. Make all four routes work through the gateway on 127.0.0.1:

           /api/users     -> users: alice bob carol
           /api/orders    -> orders: 1001 1002
           /api/version   -> upstream 1.0
           /docs/intro    -> docs: introduction

         Fix it in the proxy configuration. The traffic must still go to
         172.32.0.11:8080, and no `rewrite` directive: nginx already changes
         the path here, and the exercise is to make it change it correctly.

      2. Write /root/answers/proxy.md, exactly two lines:

           api_before: <path>
           docs_before: <path>

         What the application received, before your fix, for a request to
         /api/users and a request to /docs/intro. Copy them from its record.
      Q

      echo "scenario ready — four routes, four 404s from a healthy upstream"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      # ---- the four routes ------------------------------------------------
      check() {
        got=$(curl -s -m 8 "http://127.0.0.1$1" 2>/dev/null || true)
        if [ "$got" != "$2" ]; then
          echo "not yet: $1 returns '${got:-nothing}'."
          echo "         Expected: $2"
          case "$got" in
            "no route: /api"*)
              echo "         The upstream was asked for the path exactly as the client sent"
              echo "         it — the /api/ prefix was never removed. A proxy_pass with no"
              echo "         URI part after the host forwards the request URI unchanged."
              ;;
            "no route: /pages//"*)
              echo "         Two slashes. proxy_pass replaces the part of the URI that the"
              echo "         location matched, and this location matched '/docs' without a"
              echo "         trailing slash, so the '/' that followed it survived."
              ;;
            "no route:"*)
              echo "         That is the upstream's own 404, so the request arrived and the"
              echo "         path was wrong. curl http://172.32.0.11:8081/admin/received"
              echo "         shows exactly what it was asked for."
              ;;
            "")
              echo "         Nothing came back at all. Check nginx is running and the site"
              echo "         is still enabled: nginx -t, systemctl status nginx."
              ;;
          esac
          return 1
        fi
        return 0
      }

      ok=0
      check /api/users   'users: alice bob carol' || ok=1
      [ "$ok" -eq 0 ] || exit 1
      check /api/orders  'orders: 1001 1002' || ok=1
      [ "$ok" -eq 0 ] || exit 1
      check /api/version 'upstream 1.0' || ok=1
      [ "$ok" -eq 0 ] || exit 1
      check /docs/intro  'docs: introduction' || ok=1
      [ "$ok" -eq 0 ] || exit 1

      # ---- the answers came from the upstream ------------------------------
      #
      # A static file or a `return 200` in the location block would satisfy the
      # four checks above without proxying anything. A request with a token in
      # the query string has to show up in the upstream's own record.
      token="v$(od -An -N3 -tu4 < /dev/urandom | tr -d ' ')"
      curl -s -o /dev/null -m 8 "http://127.0.0.1/api/users?probe=$token" 2>/dev/null || true
      seen=$(curl -s -m 8 http://172.32.0.11:8081/admin/received 2>/dev/null | grep -c "$token" || true)
      if [ "$seen" -eq 0 ]; then
        echo "not yet: a request to /api/users never reached 172.32.0.11:8080."
        echo "         The four routes answer, and the upstream did not hear about it."
        echo "         Serving the bodies from nginx passes the checks and proxies"
        echo "         nothing; the next change to the application would not show up."
        exit 1
      fi

      # ---- fixed where the fault is ---------------------------------------
      conf=/etc/nginx/sites-available/gateway
      # Anywhere in the file, not just at the start of a line: a rewrite inside a
      # single-line location block is legal and does the same job.
      if grep -qE '(^|[[:space:]]|\{)rewrite[[:space:]]' "$conf" 2>/dev/null; then
        echo "not yet: there is a rewrite directive in $conf."
        echo "         It works, and it is a second mechanism doing a job the first one"
        echo "         already does. proxy_pass either forwards the URI or replaces the"
        echo "         matched prefix, and which of those it does is the trailing slash."
        exit 1
      fi

      if [ "$(grep -cE 'proxy_pass[[:space:]]+http://172\.32\.0\.11:8080' "$conf" 2>/dev/null || echo 0)" -lt 2 ]; then
        echo "not yet: $conf no longer has both routes proxying to 172.32.0.11:8080."
        exit 1
      fi

      # ---- what arrived, before the fix ------------------------------------
      if [ ! -s /root/answers/proxy.md ]; then
        echo "not yet: /root/answers/proxy.md is missing or empty."
        echo "         Both paths are in the upstream's record:"
        echo "         curl -s http://172.32.0.11:8081/admin/received"
        exit 1
      fi

      low=$(tr 'A-Z' 'a-z' < /root/answers/proxy.md)
      api=$(printf '%s\n' "$low" | sed -n 's#^[[:space:]]*api_before[[:space:]]*[:=][[:space:]]*\([^[:space:]]*\).*#\1#p' | head -1)
      docs=$(printf '%s\n' "$low" | sed -n 's#^[[:space:]]*docs_before[[:space:]]*[:=][[:space:]]*\([^[:space:]]*\).*#\1#p' | head -1)

      if [ -z "$api" ] || [ -z "$docs" ]; then
        echo "not yet: /root/answers/proxy.md needs both an api_before and a"
        echo "         docs_before line."
        exit 1
      fi

      fail=0

      if [ "$api" != "/api/users" ]; then
        fail=1
        echo "not yet: you said api_before=$api."
        case "$api" in
          /users)
            echo "         That is what it receives now, after the fix. Before it, the"
            echo "         prefix was not stripped at all."
            ;;
          *)
            echo "         The upstream's record has it verbatim. proxy_pass with no URI"
            echo "         part forwards the request URI exactly as the client sent it."
            ;;
        esac
      fi

      if [ "$docs" != "/pages//intro" ]; then
        fail=1
        echo "not yet: you said docs_before=$docs."
        case "$docs" in
          /pages/intro)
            echo "         That is the fixed one. Before the fix there was one more"
            echo "         character in it, and it is the whole reason the route 404'd."
            ;;
          /docs/intro)
            echo "         That is what the client asked for. The question is what the"
            echo "         upstream was handed after nginx replaced the matched prefix."
            ;;
          *)
            echo "         Copy it from the upstream's record verbatim, including any"
            echo "         repeated slash: curl -s http://172.32.0.11:8081/admin/received"
            ;;
        esac
      fi

      [ "$fail" -eq 0 ] || exit 1

      echo "PASS — all four routes are served by the upstream through the gateway,"
      echo "       without a rewrite, and what the upstream was being handed before"
      echo "       the fix is named exactly."
