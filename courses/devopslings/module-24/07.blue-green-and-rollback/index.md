---
kind: lesson
title: "Blue/green and rollback"
description: |
  v2 is live on green and it is bad. Get every customer back on v1 in under
  a minute — and make sure v1 can still run on the database v2 migrated, and
  v2 on the rows v1 writes after you roll back, because you will roll
  forward again.
name: blue-green-and-rollback
slug: blue-green-and-rollback
createdAt: "2026-11-14"

sandbox:
  stack: ha-stack
  service: ops

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      ha-reset
      g=/var/lib/devopslings/bluegreen
      mkdir -p "$g" /ha/sre/migrations /ha/app/routes /ha/deploy/builds
      cat > /ha/app/routes/checkout.py <<'PY'
      # GET /checkout serves the build named in /ha/deploy/<this node>, from
      # /ha/deploy/builds/<build>.py, and says which in an X-Build header.
      import importlib.util
      import socket

      NODE = socket.gethostname()
      _builds = {}


      def handle(db):
          build = open(f"/ha/deploy/{NODE}").read().strip()
          if build not in _builds:
              spec = importlib.util.spec_from_file_location(build, f"/ha/deploy/builds/{build}.py")
              mod = importlib.util.module_from_spec(spec)
              spec.loader.exec_module(mod)
              _builds[build] = mod
          code, body, *rest = _builds[build].handle(db)
          return code, body, {**(rest[0] if rest else {}), "X-Build": build}
      PY
      cat > "$g/v1.py" <<'PY'
      # checkout v1: place an order, show the five newest.
      import uuid
      def handle(db):
          with db() as c:
              c.execute("INSERT INTO bg.orders (reference) VALUES (%s)", (uuid.uuid4().hex[:10],))
              rows = c.execute("SELECT reference, placed_at FROM bg.orders ORDER BY id DESC LIMIT 5").fetchall()
          return 200, {"build": "v1", "recent": [f"{r} {t:%H:%M:%S}" for r, t in rows]}
      PY
      cat > "$g/v2.py" <<'PY'
      # checkout v2: orders carry a currency, and the history says when, as created_at.
      import uuid
      def handle(db):
          with db() as c:
              c.execute("INSERT INTO bg.orders (reference, currency) VALUES (%s, %s)", (uuid.uuid4().hex[:10], "GBP"))
              rows = c.execute("SELECT reference, currency, created_at FROM bg.orders ORDER BY id DESC LIMIT 5").fetchall()
          return 200, {"build": "v2", "recent": [f"{r} {cur.upper()} {t:%H:%M:%S}" for r, cur, t in rows]}
      PY
      cat > "$g/schema-v1.sql" <<'SQL'
      DROP SCHEMA IF EXISTS bg CASCADE;
      CREATE SCHEMA bg;
      CREATE TABLE bg.orders (
        id        bigserial PRIMARY KEY,
        reference text NOT NULL,
        placed_at timestamptz NOT NULL DEFAULT now()
      );
      INSERT INTO bg.orders (reference, placed_at)
        SELECT 'v1-' || g, now() - g * interval '7 minutes' FROM generate_series(1, 50) g;
      SQL
      cat > "$g/haproxy-green.cfg" <<'CFG'
      # Blue/green: two backends, and www sends everyone to one of them.
      frontend www
          bind :80
          default_backend green

      backend blue
          option httpchk GET /health
          server web1 172.29.22.21:8080 check inter 1s fall 2 rise 2

      backend green
          option httpchk GET /health
          server web2 172.29.22.22:8080 check inter 1s fall 2 rise 2
      CFG
      cp "$g/v1.py" "$g/v2.py" /ha/deploy/builds/
      cp "$g/haproxy-green.cfg" /ha/sre/haproxy-green.cfg
      cat > /ha/sre/migrations/002-v2.sql <<'SQL'
      -- Shipped with v2.
      ALTER TABLE bg.orders RENAME COLUMN placed_at TO created_at;
      ALTER TABLE bg.orders ADD COLUMN currency text NOT NULL DEFAULT 'EUR';
      -- Every new order must say its currency; the default was only for the old rows.
      ALTER TABLE bg.orders ALTER COLUMN currency DROP DEFAULT;
      SQL
      cat > /ha/sre/deploy <<'SH'
      #!/bin/bash
      # deploy <node> <build> — build the image, push it, roll it out to the node.
      node=${1:?usage: deploy <node> <build>}; build=${2:?usage: deploy <node> <build>}
      [ -f "/ha/deploy/builds/$build.py" ] || { echo "no such build: $build" >&2; exit 1; }
      echo "building $build..."; sleep 30
      echo "pushing..."; sleep 25
      echo "rolling out to $node..."; sleep 20
      echo "$build" > "/ha/deploy/$node"
      echo "done: $node runs $build"
      SH
      chmod +x /ha/sre/deploy
      rm -f /ha/sre/rollback
      psql -qX -f "$g/schema-v1.sql" >/dev/null
      psql -qX -f /ha/sre/migrations/002-v2.sql
      echo v1 > /ha/deploy/web1
      echo v2 > /ha/deploy/web2
      cp "$g/haproxy-green.cfg" /ha/haproxy.cfg
      for _ in $(seq 20); do [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://www/checkout)" != 000 ] && break; sleep 0.5; done
      echo "scenario ready — v2 went live on green at 09:40. It is 09:52, and v2 is bad."
      echo
      echo "  blue  = web1, v1        green = web2, v2        www -> green"
      echo
      echo "  what blue answers now:  $(curl -s --max-time 5 http://web1:8080/checkout | cut -c1-150)"
      echo
      echo "  the load balancer:      /ha/haproxy.cfg   (cutover state: /ha/sre/haproxy-green.cfg)"
      echo "  v2's migration:         /ha/sre/migrations/002-v2.sql"
      echo "  the deploy tool:        /ha/sre/deploy <node> <build>"
      echo "  your rollback:          /ha/sre/rollback"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      g=/var/lib/devopslings/bluegreen
      if [ ! -f "$g/haproxy-green.cfg" ]; then
        echo "not yet: the scenario's files are missing. Reset the lesson."
        exit 1
      fi
      if [ ! -x /ha/sre/rollback ]; then
        echo "not yet: /ha/sre/rollback is missing or not executable."
        exit 1
      fi
      tmp=$(mktemp -d)
      trap 'rm -rf "$tmp"' EXIT
      build_on() { curl -s -o /dev/null -D - --max-time 5 "http://$1/checkout" 2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1) == "x-build" { print $2 }' || true; }
      wait_build() {  # wait_build <host> <build> <seconds>
        for _ in $(seq $(($3 * 2))); do [ "$(build_on "$1")" = "$2" ] && return 0; sleep 0.5; done
        return 1
      }

      # The database as v1 left it, then the migration as it is now written.
      psql -qX -f "$g/schema-v1.sql" >/dev/null
      if ! out=$(psql -qX -v ON_ERROR_STOP=1 -f /ha/sre/migrations/002-v2.sql 2>&1); then
        echo "not yet: /ha/sre/migrations/002-v2.sql does not apply to v1's schema:"
        printf '%s\n' "$out" | tail -3 | sed 's/^/         | /'
        exit 1
      fi
      cp "$g/v1.py" "$g/v2.py" /ha/deploy/builds/
      echo v1 > /ha/deploy/web1
      echo v2 > /ha/deploy/web2
      cp "$g/haproxy-green.cfg" /ha/haproxy.cfg
      if ! wait_build lb1 v2 15 || ! wait_build lb2 v2 15; then
        body=$(curl -s --max-time 5 http://web2:8080/checkout | cut -c1-200 || true)
        echo "not yet: with green live, v2 does not serve checkout. web2 answers:"
        echo "         | $body"
        echo "         The migration has to give v2 what it reads: a currency, and created_at."
        exit 1
      fi
      echo "green is live: v2 runs on the migrated schema"

      # Customers keep coming while the rollback runs.
      python3 - 75 > "$tmp/load" <<'PY' &
      import sys, threading, time, urllib.error, urllib.request
      end = time.time() + float(sys.argv[1])
      lock = threading.Lock()
      def worker():
          while time.time() < end:
              t = time.time()
              try:
                  with urllib.request.urlopen("http://www/checkout", timeout=5) as r:
                      st, b, body = r.status, r.headers.get("X-Build", "-"), ""
                      r.read()
              except urllib.error.HTTPError as e:
                  st, b, body = e.code, e.headers.get("X-Build", "-"), " ".join(e.read().decode(errors="replace").split())[:160]
              except Exception as e:
                  st, b, body = 0, "-", type(e).__name__
              with lock:
                  print(f"{t:.3f} {st} {b} {body}", flush=True)
              time.sleep(0.05)
      ts = [threading.Thread(target=worker) for _ in range(4)]
      [x.start() for x in ts]
      [x.join() for x in ts]
      PY
      load=$!
      sleep 3
      t0=$(date +%s.%N)
      rc=0
      timeout 60 /ha/sre/rollback > "$tmp/rollback" 2>&1 || rc=$?
      t1=$(date +%s.%N)
      took=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1f", b - a }')
      if [ "$rc" = 124 ]; then
        kill "$load" 2>/dev/null || true
        echo "not yet: /ha/sre/rollback was still running after 60 seconds. Its output:"
        tail -n 3 "$tmp/rollback" | sed 's/^/         | /'
        if grep -q '/ha/sre/deploy' /ha/sre/rollback; then
          echo "         It calls /ha/sre/deploy, which takes over a minute: build, push, roll out. Blue is"
          echo "         still running v1. Rolling back is moving traffic to it, not rebuilding it."
        fi
        exit 1
      fi
      if [ "$rc" != 0 ]; then
        kill "$load" 2>/dev/null || true
        echo "not yet: /ha/sre/rollback exited $rc. Its output:"
        tail -n 3 "$tmp/rollback" | sed 's/^/         | /'
        exit 1
      fi
      wait "$load" || true

      # From 5 seconds after the rollback returned, every request must be v1 and good.
      after=$(awk -v t="$t1" '$1 > t + 5' "$tmp/load")
      n=$(printf '%s\n' "$after" | grep -c . || true)
      v2=$(printf '%s\n' "$after" | awk '$3 == "v2"' | grep -c . || true)
      bad=$(printf '%s\n' "$after" | awk '$2 != 200' | grep -c . || true)
      if [ "$v2" -gt 0 ]; then
        echo "not yet: the rollback returned after ${took}s, and $v2 of the $n requests that came after still"
        echo "         went to v2. www should be sending everyone to blue."
        exit 1
      fi
      if [ "$bad" -gt 0 ]; then
        echo "not yet: after the rollback, $bad of $n requests to v1 failed. One of them:"
        printf '%s\n' "$after" | awk '$2 != 200' | head -1 | cut -d' ' -f2- | sed 's/^/         | /'
        echo "         v1 is running against the schema v2's migration left behind. Whatever the migration"
        echo "         changed, v1's code has to keep working on it, or there is nothing to roll back to."
        exit 1
      fi
      during=$(awk -v a="$t0" -v b="$t1" '$1 >= a - 1 && $1 <= b + 5 && $2 == 0' "$tmp/load" | grep -c . || true)
      if [ "$during" -gt 0 ]; then
        echo "not yet: $during requests during the rollback got no answer at all (connection refused or"
        echo "         reset). Moving traffic should not drop the customers already in flight."
        exit 1
      fi
      for lb in lb1 lb2; do
        if [ "$(build_on "$lb")" != v1 ]; then
          echo "not yet: www answers from v1, but $lb still sends checkout to $(build_on "$lb"). If the address"
          echo "         moves to $lb, customers are back on v2. A change made through one load balancer's"
          echo "         runtime API lives only in that process; /ha/haproxy.cfg is shared by both."
          exit 1
        fi
      done
      echo "rolled back in ${took}s: $n requests after it, all v1, all good, on lb1 and lb2"

      # v2 is fixed and goes out again: it must read the rows v1 wrote meanwhile.
      # Its first request is the test, while v1's orders are still the newest.
      first=$(curl -s -o "$tmp/first" -w '%{http_code}' --max-time 5 http://web2:8080/checkout || true)
      cp "$g/haproxy-green.cfg" /ha/haproxy.cfg
      if [ "$first" != 200 ] || ! wait_build lb1 v2 15; then
        body=$(cut -c1-200 "$tmp/first" 2>/dev/null || true)
        echo "not yet: rolling forward again, v2 fails on the orders v1 wrote during the rollback:"
        echo "         | $body"
        echo "         Rows v1 writes do not set the columns v2 added. Whatever v2 reads from them has to"
        echo "         have a value: a default, or a column the database computes."
        exit 1
      fi
      drift=$(psql -qtAX -c "SELECT count(*) FROM bg.orders WHERE created_at IS DISTINCT FROM placed_at" 2>/dev/null || echo "?")
      if [ "$drift" != 0 ]; then
        echo "not yet: $drift orders show v2 a created_at that is not when they were placed (placed_at)."
        echo "         v2 tells customers when they ordered; v1 records it. Both columns describe one moment."
        exit 1
      fi
      echo "rolled forward: v2 reads every order v1 wrote, with the time it was placed"
      echo
      echo "PASS — back on v1 in ${took}s, with a schema both versions can run on."
---
