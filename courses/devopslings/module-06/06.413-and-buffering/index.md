---
kind: lesson
title: "uploads fail at exactly one megabyte, and the app never sees them"
description: |
  Anything under a megabyte uploads fine. Anything over it gets 413, and the
  application logs nothing at all — because the request never reached it. The
  limit belongs to the proxy, and so does the reason the limit exists: by
  default the whole body is spooled to disk before the upstream is contacted.
name: 413-and-buffering
slug: 413-and-buffering
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
      rm -f /etc/nginx/sites-enabled/* /etc/nginx/sites-available/uploads
      rm -f /etc/nginx/conf.d/cache.conf /root/answers/upload.md
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

      # ---- the upload endpoint -------------------------------------------
      #
      # Nothing has been set here. That is the scenario: nginx's own default
      # client_max_body_size is 1m, and the default proxy_request_buffering is
      # on. Both defaults are deliberate and both are wrong for this route.
      cat > /etc/nginx/sites-available/uploads <<'CONF'
      server {
          listen 80 default_server;
          server_name _;

          location / {
              proxy_pass http://172.32.0.11:8080;
          }
      }
      CONF
      ln -sf /etc/nginx/sites-available/uploads /etc/nginx/sites-enabled/uploads

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

      dd if=/dev/zero of=/root/upload-25m.bin bs=1M count=25 2>/dev/null

      cat > /root/questions.txt <<'Q'
      The upload endpoint takes anything small and nothing large:

        $ head -c 1000000 /dev/zero | curl -s --data-binary @- \
            -o /dev/null -w '%{http_code}\n' http://127.0.0.1/upload
        200
        $ head -c 1100000 /dev/zero | curl -s --data-binary @- \
            -o /dev/null -w '%{http_code}\n' http://127.0.0.1/upload
        413

      The application logs nothing for the failing ones. Its own record of what
      it received has no entry for them at all:

        $ curl -s http://172.32.0.11:8081/admin/received

      A 25 MB file is at /root/upload-25m.bin. The edge is nginx on this box,
      /etc/nginx/sites-available/uploads. The application is not yours.

      Three requirements from the platform team.

      1. A 25 MB upload must succeed, and the application must report receiving
         all 26214400 bytes.

      2. A limit must remain. 64 MB is above what this endpoint is for and must
         still be refused with 413. "No limit" is not an answer — the body is
         spooled somewhere before it is forwarded, and an unbounded body is an
         unbounded amount of somewhere.

      3. Uploads must be streamed rather than spooled: the application has to
         see the request while the client is still sending it, not only once the
         whole body has arrived. This is checked by uploading at a throttled
         rate and watching when the application first hears about it.

      Then write /root/answers/upload.md, exactly two lines:

        rejected_by: <one word>
        limit_bytes: <number>

      rejected_by is which component produced the 413 — the proxy or the origin.
      limit_bytes is the limit that was in force before you changed anything, in
      bytes.
      Q

      echo "scenario ready — 413 above 1 MB, nothing reaching the origin"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 600
    run: |
      admin=http://172.32.0.11:8081

      # ---- the 25 MB upload the ticket is about ----------------------------
      out=$(curl -s -m 120 --data-binary @/root/upload-25m.bin http://127.0.0.1/upload 2>/dev/null || true)
      if ! printf '%s' "$out" | grep -q 'stored bytes=26214400'; then
        code=$(curl -s -o /dev/null -m 120 -w '%{http_code}' --data-binary @/root/upload-25m.bin http://127.0.0.1/upload 2>/dev/null || echo 000)
        echo "not yet: the 25 MB upload returned $code."
        if [ "$code" = "413" ]; then
          echo "         413 is the proxy refusing to read the body. The origin never"
          echo "         sees these requests, which is why it has nothing to log."
          echo "         nginx's default client_max_body_size is 1m."
        else
          echo "         The origin said: ${out:-nothing}"
        fi
        exit 1
      fi

      # ---- a limit still exists --------------------------------------------
      tmp=$(mktemp)
      dd if=/dev/zero of="$tmp" bs=1M count=64 2>/dev/null
      code=$(curl -s -o /dev/null -m 180 -w '%{http_code}' --data-binary @"$tmp" http://127.0.0.1/upload 2>/dev/null || echo 000)
      rm -f "$tmp"
      if [ "$code" != "413" ]; then
        echo "not yet: a 64 MB upload returned $code, and it has to be refused with 413."
        if [ "$code" = "200" ]; then
          echo "         client_max_body_size 0 removes the limit rather than raising it."
          echo "         Whatever is spooling or streaming that body has to be bounded by"
          echo "         something, and the proxy is the only thing here that can."
        fi
        exit 1
      fi

      # ---- and they are streamed, not spooled -------------------------------
      #
      # A throttled upload, and the question is when the origin first hears
      # about it. With the body buffered, nginx reads all of it before opening
      # the upstream request, so the origin learns about the upload at the
      # moment the client finishes. Streamed, it knows almost immediately.
      curl -s -X POST -m 5 "$admin/admin/reset" >/dev/null 2>&1 || true
      ( head -c 5242880 /dev/zero | curl -s -m 120 --limit-rate 1000k \
          --data-binary @- -o /dev/null http://127.0.0.1/upload 2>/dev/null || true ) &
      client=$!
      start=$(date +%s%N)
      seen=""
      while kill -0 "$client" 2>/dev/null; do
        if curl -s -m 2 "$admin/admin/received" 2>/dev/null | grep -q upload; then
          seen=$(( ($(date +%s%N) - start) / 1000000 ))
          break
        fi
        sleep 0.2
      done
      wait "$client" 2>/dev/null || true
      total=$(( ($(date +%s%N) - start) / 1000000 ))
      : "${seen:=$total}"

      if [ "$seen" -gt $(( total / 2 )) ]; then
        echo "not yet: the client spent ${total}ms sending, and the origin did not hear"
        echo "         about the upload until ${seen}ms in — which is when the sending"
        echo "         finished, not when it started."
        echo "         With the request body buffered, nginx reads the whole thing to"
        echo "         disk before it opens the connection to the upstream. That is the"
        echo "         default, and it is why the size limit exists at all."
        exit 1
      fi

      # ---- naming it --------------------------------------------------------
      if [ ! -s /root/answers/upload.md ]; then
        echo "not yet: /root/answers/upload.md is missing or empty."
        exit 1
      fi

      low=$(tr 'A-Z' 'a-z' < /root/answers/upload.md)
      rb=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*rejected_by[[:space:]]*[:=][[:space:]]*\([a-z]*\).*/\1/p' | head -1)
      lb=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*limit_bytes[[:space:]]*[:=][[:space:]]*\([0-9]*\).*/\1/p' | head -1)

      if [ -z "$rb" ] || [ -z "$lb" ]; then
        echo "not yet: /root/answers/upload.md needs a rejected_by line and a"
        echo "         limit_bytes line."
        exit 1
      fi

      fail=0

      case "$rb" in
        proxy|nginx|edge) ;;
        origin|app|upstream)
          fail=1
          echo "not yet: you said rejected_by=$rb."
          echo "         The origin never received those requests — its own record of"
          echo "         what it was asked for has no entry for them. It cannot have"
          echo "         rejected something it never saw."
          ;;
        *)
          fail=1
          echo "not yet: rejected_by=$rb is not one of proxy or origin."
          ;;
      esac

      if [ "$lb" != "1048576" ]; then
        fail=1
        echo "not yet: you said limit_bytes=$lb."
        case "$lb" in
          1000000)
            echo "         That is a megabyte counted in thousands. nginx's 1m is 1024"
            echo "         times 1024."
            ;;
          1|1048577|33554432)
            echo "         The question is the limit that was in force before you changed"
            echo "         anything, in bytes."
            ;;
          *)
            echo "         nginx's default client_max_body_size is 1m. In bytes."
            ;;
        esac
      fi

      [ "$fail" -eq 0 ] || exit 1

      echo "PASS — 25 MB arrives whole, 64 MB is still refused, the origin hears about"
      echo "       an upload while it is still being sent, and the 413 is attributed to"
      echo "       the component that produced it."
