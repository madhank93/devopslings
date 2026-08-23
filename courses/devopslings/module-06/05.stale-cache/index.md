---
kind: lesson
title: "the deploy went out and the browser still has yesterday"
description: |
  A new build is live on the origin and users keep getting the old one, even
  though every URL is fingerprinted and should be a cache miss. And on the
  page that is different for every user, some of them are seeing someone
  else's. Two lines of cache configuration, both of which look like tuning.
name: stale-cache
slug: stale-cache
createdAt: "2026-08-23"

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
      rm -f /etc/nginx/sites-enabled/* /etc/nginx/sites-available/edge
      rm -f /etc/nginx/conf.d/cache.conf /root/answers/cache.md
      rm -rf /var/cache/nginx/edge
      # The package does not ship a cache directory, because the default config
      # does not cache. nginx will create the leaf but not the parent.
      install -d -o www-data -g www-data /var/cache/nginx
      install -d /root/answers

      curl -s -X POST -m 3 'http://172.32.0.11:8081/admin/reset' >/dev/null 2>&1 || true
      ready=""
      for _ in $(seq 1 40); do
        if curl -s -m 2 http://172.32.0.11:8080/asset.js 2>/dev/null | grep -q build; then
          ready=yes
          break
        fi
        sleep 0.5
      done
      if [ -z "$ready" ]; then
        echo "the origin on 172.32.0.11:8080 never came up"
        exit 1
      fi

      # ---- the edge cache ------------------------------------------------
      #
      # Both of the faults here are lines somebody added on purpose, for a
      # reason that was true at the time.
      #
      # The cache key uses $uri, which is the path with the query string
      # removed. Written that way, /asset.js?v=1 and /asset.js?v=9 are the same
      # cache entry — so fingerprinting the URL, the entire mechanism a deploy
      # relies on to bust the cache, does nothing.
      #
      # proxy_ignore_headers Vary makes nginx cache one copy of a response that
      # the origin explicitly said depends on a request header. It is usually
      # added to raise a hit ratio, and it is how one user is served another
      # user's page.
      cat > /etc/nginx/conf.d/cache.conf <<'CACHE'
      proxy_cache_path /var/cache/nginx/edge levels=1:2 keys_zone=edge:10m
                       max_size=100m inactive=10m;
      CACHE

      cat > /etc/nginx/sites-available/edge <<'CONF'
      server {
          listen 80 default_server;
          server_name _;

          location / {
              proxy_pass http://172.32.0.11:8080;
              proxy_cache edge;

              proxy_cache_key "$scheme$request_method$host$uri";
              proxy_ignore_headers Vary;

              proxy_cache_valid 200 60s;
              add_header X-Cache-Status $upstream_cache_status always;
          }
      }
      CONF
      ln -sf /etc/nginx/sites-available/edge /etc/nginx/sites-enabled/edge

      if ! nginx -t 2>/tmp/nginx-t; then
        echo "the scenario's own nginx config did not load:"
        cat /tmp/nginx-t
        exit 1
      fi
      systemctl enable --now nginx.service >/dev/null 2>&1
      systemctl reload nginx.service 2>/dev/null || systemctl restart nginx.service

      for _ in $(seq 1 20); do
        curl -s -o /dev/null -m 2 http://127.0.0.1/asset.js && break
        sleep 0.5
      done

      # Warm the cache the way a day of traffic would, so the symptom is present
      # the moment the student looks rather than after they cause it.
      curl -s -o /dev/null -m 3 'http://127.0.0.1/asset.js?v=1' || true
      curl -s -o /dev/null -m 3 -H 'X-User: alice' http://127.0.0.1/profile || true

      cat > /root/questions.txt <<'Q'
      Build 2 went out this morning. The origin is serving it:

        $ curl -s http://172.32.0.11:8080/asset.js
        console.log('build 2');

      Through the edge, with the fingerprinted URL the new page asks for:

        $ curl -s 'http://127.0.0.1/asset.js?v=2'
        console.log('build 1');

      Yesterday's build, for a URL that has never been requested before.

      There is a second report, from support. The profile page is per-user and
      the origin says so — it sends `Vary: X-User`. Some users are seeing
      somebody else's:

        $ curl -s -H 'X-User: alice' http://127.0.0.1/profile
        profile: alice
        $ curl -s -H 'X-User: bob' http://127.0.0.1/profile
        profile: alice

      The edge is nginx on this box: /etc/nginx/sites-available/edge and
      /etc/nginx/conf.d/cache.conf. The origin is not yours.

      Every response carries X-Cache-Status, so you can see what the cache
      thought it was doing:

        $ curl -si 'http://127.0.0.1/asset.js?v=2' | grep -i x-cache

      The origin records every request it receives, which is how you can tell a
      hit from a miss without believing the header:

        $ curl -s http://172.32.0.11:8081/admin/received

      Whatever was cached while the edge was behaving this way is still on disk
      and still wrong. Changing the configuration changes what happens to the
      next request, not what is already stored.

      Three things to do.

      1. A newly deployed build must be served immediately at its own URL. You
         will be graded by deploying a build, letting the edge cache it, then
         deploying another and asking for the new one.

      2. A user must never be served another user's profile.

      3. The cache must still be a cache. Twenty identical requests are sent
         and the origin must see no more than three of them. Turning caching
         off, or making every request a miss, fixes the first two problems and
         is not a fix — it moves every byte of load onto the origin.

      Then write /root/answers/cache.md, exactly two lines:

        key_missing: <one word>
        vary_header: <header name>

      key_missing is what the cache key left out. vary_header is the header the
      origin said the profile response depends on.
      Q

      echo "scenario ready — fingerprinted URLs ignored, Vary ignored"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      origin=http://172.32.0.11:8080
      admin=http://172.32.0.11:8081

      deploy() { curl -s -X POST -m 5 "$admin/admin/deploy?version=$1" >/dev/null 2>&1 || true; }

      # ---- a deploy has to be visible --------------------------------------
      #
      # Two deploys, not one. The first warms the edge with a build under a
      # fingerprinted URL; the second asks for a URL that has never been seen
      # before. A cache key that drops the query string answers the second
      # request out of the first request's entry, which is the whole fault —
      # and no amount of purging beforehand changes that.
      old=$(( (RANDOM % 400) + 100 ))
      new=$(( old + 1 ))

      deploy "$old"
      warm=$(curl -s -m 8 "http://127.0.0.1/asset.js?v=$old" 2>/dev/null || true)
      if ! printf '%s' "$warm" | grep -q "build $old"; then
        echo "not yet: /asset.js?v=$old returned '${warm:-nothing}' rather than build $old."
        echo "         The origin is serving that build; the edge is not passing it on."
        exit 1
      fi

      deploy "$new"
      got=$(curl -s -m 8 "http://127.0.0.1/asset.js?v=$new" 2>/dev/null || true)
      if ! printf '%s' "$got" | grep -q "build $new"; then
        echo "not yet: after deploying build $new, /asset.js?v=$new served"
        echo "         '${got:-nothing}'."
        echo "         That URL had never been requested before, so it cannot have been"
        echo "         in the cache — unless the cache key does not include the part of"
        echo "         the URL that changed. \$uri is the path with the query string"
        echo "         removed; \$request_uri is the whole thing."
        exit 1
      fi

      # ---- one user must not be served another's ---------------------------
      a=$(curl -s -m 8 -H 'X-User: alice' http://127.0.0.1/profile 2>/dev/null || true)
      b=$(curl -s -m 8 -H 'X-User: bob' http://127.0.0.1/profile 2>/dev/null || true)
      if [ "$a" != "profile: alice" ] || [ "$b" != "profile: bob" ]; then
        echo "not yet: alice got '${a:-nothing}' and bob got '${b:-nothing}'."
        echo "         The origin sends 'Vary: X-User' on that response, which is it"
        echo "         telling the cache that one stored copy is not enough. nginx obeys"
        echo "         Vary unless something tells it not to."
        if [ "$a" = "$b" ]; then
          echo "         If the configuration is already right, the entry stored while it"
          echo "         was wrong is still there and still wrong. Corrupted entries have"
          echo "         to be removed; they do not repair themselves."
        fi
        exit 1
      fi

      # ---- and it still has to be a cache ----------------------------------
      curl -s -X POST -m 5 "$admin/admin/reset" >/dev/null 2>&1 || true
      deploy "$new"
      probe="http://127.0.0.1/asset.js?v=$new"
      curl -s -o /dev/null -m 8 "$probe" 2>/dev/null || true
      curl -s -X POST -m 5 "$admin/admin/reset" >/dev/null 2>&1 || true
      deploy "$new"
      for _ in $(seq 1 20); do
        curl -s -o /dev/null -m 8 "$probe" 2>/dev/null || true
      done
      seen=$(curl -s -m 5 "$admin/admin/received" 2>/dev/null | grep -c 'asset.js' || true)
      : "${seen:=0}"
      if [ "$seen" -gt 3 ]; then
        echo "not yet: twenty identical requests reached the origin $seen times."
        echo "         Correct and uncached is not the goal — the edge exists so the"
        echo "         origin does not see this traffic. A key with something unique in"
        echo "         it, no_cache, or caching turned off all pass the two checks above"
        echo "         and hand every request to the origin."
        exit 1
      fi

      # ---- naming it --------------------------------------------------------
      if [ ! -s /root/answers/cache.md ]; then
        echo "not yet: /root/answers/cache.md is missing or empty."
        exit 1
      fi

      low=$(tr 'A-Z' 'a-z' < /root/answers/cache.md)
      km=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*key_missing[[:space:]]*[:=][[:space:]]*\([a-z_ -]*\).*/\1/p' | head -1 | tr -d ' ')
      vh=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*vary_header[[:space:]]*[:=][[:space:]]*\([a-z0-9_-]*\).*/\1/p' | head -1)

      if [ -z "$km" ] || [ -z "$vh" ]; then
        echo "not yet: /root/answers/cache.md needs a key_missing line and a"
        echo "         vary_header line."
        exit 1
      fi

      fail=0

      case "$km" in
        query|querystring|query-string|args|arguments|request_uri) ;;
        *)
          fail=1
          echo "not yet: you said key_missing=$km."
          case "$km" in
            uri|path)
              echo "         The path was in the key — it was the only thing in it. What"
              echo "         was left out is the part after the '?'."
              ;;
            *)
              echo "         Compare \$uri with \$request_uri. One of them stops at the"
              echo "         '?'; the deploy's cache busting lives after it."
              ;;
          esac
          ;;
      esac

      if [ "$vh" != "x-user" ]; then
        fail=1
        echo "not yet: you said vary_header=$vh."
        echo "         Read the response the origin sends for /profile:"
        echo "         curl -si http://172.32.0.11:8080/profile | grep -i vary"
      fi

      [ "$fail" -eq 0 ] || exit 1

      echo "PASS — a new build is served at its own URL, no user gets another's page,"
      echo "       and twenty identical requests still cost the origin at most three."
