---
kind: lesson
title: "Rotating the password drops requests"
description: |
  orders reads its database password from OpenBao, and rotate.sh changes it.
  Every rotation fails a burst of requests, so it is only ever run at 3 a.m.,
  and lately not at all. Make rotation safe to run at noon, under load, with
  zero failed requests.
name: rotation-without-downtime
slug: rotation-without-downtime
createdAt: "2026-10-14"
timingSensitive: true

sandbox:
  stack: ci-stack
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 600
    run: |
      L=../../courses/devopslings/module-16/06.rotation-without-downtime
      G=$L/rotation.compose.yaml
      S=../../scratch/rotation-without-downtime
      dc() { docker compose -f compose.yaml -f "$G" "$@"; }
      bao() { dc exec -T -e BAO_TOKEN=devopslings-root bao bao "$@"; }
      psql() { dc exec -T db psql -U postgres -d app -v ON_ERROR_STOP=1 -qAt "$@"; }

      mkdir -p "$S"
      rm -f "$S/stop"
      cp "$L/starter/rotate.sh" "$S/rotate.sh"

      # Roles from an earlier attempt (orders_blue, orders_2, ...) go too, or
      # an old login would still work and be graded as this attempt's.
      pw=$(head -c 18 /dev/urandom | base64 | tr -d '/+=')
      psql >/dev/null <<SQL
      DROP TABLE IF EXISTS orders;
      DO \$\$
      DECLARE r text;
      BEGIN
        FOR r IN SELECT rolname FROM pg_roles WHERE rolname LIKE 'orders%' LOOP
          EXECUTE format('DROP ROLE %I', r);
        END LOOP;
      END \$\$;
      CREATE TABLE orders (id serial PRIMARY KEY, item text);
      INSERT INTO orders (item) SELECT 'item ' || g FROM generate_series(1, 25) g;
      CREATE ROLE orders LOGIN PASSWORD '$pw';
      GRANT SELECT ON orders TO orders;
      SQL

      bao kv metadata delete secret/orders/db >/dev/null 2>&1 || true
      bao kv put secret/orders/db username=orders password="$pw" >/dev/null

      printf '%s\n' 'path "secret/data/orders/db" {' '  capabilities = ["read"]' '}' \
        | bao policy write orders - >/dev/null
      token=$(bao token create -policy=orders -field=token | tr -d '\r')

      # .env is the student's file and outlives `compose down`, so it is reset.
      cat > .env <<ENV
      COMPOSE_FILE=compose.yaml:$G
      COMPOSE_PROJECT_NAME=devopslings-ci-stack
      ORDERS_BAO_TOKEN=$token
      ENV

      dc up -d --build --force-recreate orders loadgen >/dev/null 2>&1
      for _ in $(seq 40); do
        curl -fsS --max-time 3 http://127.0.0.1:18168/order >/dev/null 2>&1 && break
        sleep 0.5
      done

      echo "scenario ready — orders is serving:"
      curl -sS --max-time 3 http://127.0.0.1:18168/order || true
      echo
      echo "At verify time the check puts steady load on orders and runs"
      echo "scratch/rotation-without-downtime/rotate.sh in the middle of it."

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 420
    run: |
      L=../../courses/devopslings/module-16/06.rotation-without-downtime
      G=$L/rotation.compose.yaml
      S=../../scratch/rotation-without-downtime
      dc() { docker compose -f compose.yaml -f "$G" "$@"; }
      bao() { dc exec -T -e BAO_TOKEN=devopslings-root bao bao "$@"; }
      kv() { bao kv get -field="$1" ${2:+-version=$2} secret/orders/db 2>/dev/null | tr -d '\r' || true; }
      version() {
        bao kv metadata get -format=json secret/orders/db 2>/dev/null | tr -d ' \r\n' \
          | sed -n 's/.*"current_version":\([0-9]*\).*/\1/p' || true
      }
      # Logs in from another container, over the network, as orders does.
      login() {
        dc exec -T loadgen python3 -c 'import sys, psycopg
      psycopg.connect(host="db", dbname="app", user=sys.argv[1], password=sys.argv[2], connect_timeout=3).close()' \
          "$1" "$2" >/dev/null 2>&1
      }

      if [ ! -f "$S/rotate.sh" ]; then
        echo "not yet: scratch/rotation-without-downtime/rotate.sh is missing. Reset the lesson to get it back."
        exit 1
      fi
      for s in orders loadgen; do
        if [ -z "$(dc ps -q --status running "$s" 2>/dev/null || true)" ]; then
          echo "not yet: $s is not running. From sandboxes/ci-stack: docker compose up -d"
          exit 1
        fi
      done

      # The starting point must work, or the rotation is not what failed.
      u0=$(kv username); p0=$(kv password); v0=$(version)
      if [ -z "$u0" ] || ! login "$u0" "$p0"; then
        echo "not yet: before any rotation, the credential in secret/orders/db (${u0:-none})"
        echo "         does not log in. An earlier rotate.sh left OpenBao and Postgres out of"
        echo "         step. Fix them by hand, or reset the lesson."
        exit 1
      fi
      if ! curl -fsS --max-time 5 http://127.0.0.1:18168/order >/dev/null 2>&1; then
        sleep "$(sed -n 's/^CRED_TTL = //p' "$L/orders.py")"
        if ! curl -fsS --max-time 5 http://127.0.0.1:18168/order >/dev/null 2>&1; then
          echo "not yet: orders is failing before any rotation:"
          echo "         $(curl -sS --max-time 5 http://127.0.0.1:18168/order 2>&1 || true)"
          exit 1
        fi
      fi

      # Load first, then the rotation in the middle of it.
      work=$(mktemp -d)
      trap 'rm -rf "$work"; touch "$S/stop"' EXIT
      rm -f "$S/stop"
      dc exec -T loadgen python3 /lesson/load.py > "$work/load.out" 2>&1 &
      load=$!
      sleep 3

      rc=0
      COMPOSE_FILE="compose.yaml:$G" bash "$S/rotate.sh" > "$work/rotate.out" 2>&1 &
      rot=$!
      # Detached from this task's output, or its orphaned sleep holds the
      # runner's pipe open for the full two minutes.
      ( sleep 120; kill "$rot" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
      watchdog=$!
      wait "$rot" || rc=$?
      kill "$watchdog" 2>/dev/null || true

      sleep 3
      touch "$S/stop"
      wait "$load" || true

      ok=$(sed -n 's/^ok //p' "$work/load.out" | head -1 || true)
      fail=$(sed -n 's/^fail //p' "$work/load.out" | head -1 || true)
      first=$(grep -m1 '^failure ' "$work/load.out" | cut -d' ' -f2- | sed 's/ error .*FATAL: / /' || true)

      if [ "$rc" -ne 0 ]; then
        echo "not yet: rotate.sh exited $rc$([ "$rc" -ge 128 ] && echo ' (stopped after 120s)'):"
        tail -3 "$work/rotate.out" | sed 's/^/         /'
        exit 1
      fi
      if [ -z "$ok" ]; then
        echo "not yet: the load test did not report. This is a harness problem, not your"
        echo "         answer: reset the lesson and retry."
        tail -3 "$work/load.out" | sed 's/^/         /'
        exit 1
      fi

      u1=$(kv username); p1=$(kv password)
      if ! login "$u1" "$p1"; then
        echo "not yet: after rotate.sh, the credential in secret/orders/db ($u1) does not"
        echo "         log in. OpenBao and Postgres disagree, and orders is down from here on."
        exit 1
      fi

      if [ "${fail:-0}" -gt 0 ]; then
        down=$(grep -c '^failure [0-9.]* no answer' "$work/load.out" || true)
        if [ "${down:-0}" -gt 0 ]; then
          echo "not yet: $fail of $((ok + fail)) requests failed, $down of them with no answer from"
          echo "         orders. The service was taken down during the rotation. Zero failed"
          echo "         requests means it keeps serving the whole time."
          exit 1
        fi
        # Did any value rotate.sh published hold two credentials at once?
        dual=0
        v1=$(version)
        for ((v = v0 + 1; v <= ${v1:-0}; v++)); do
          if [ -n "$(kv previous_password "$v")" ] || [ "$(kv username "$v")" != "$u0" ]; then
            dual=1
          fi
        done
        echo "not yet: $fail of $((ok + fail)) requests failed during the rotation. The first,"
        echo "         ${first%% *}s into the test: ${first#* }"
        if [ "$dual" = 0 ]; then
          echo "         rotate.sh never published two working credentials at once, so for a"
          echo "         while the copy orders held did not match the database: until its next"
          echo "         fetch from OpenBao, which it caches for 10s."
        else
          echo "         rotate.sh did publish two credentials, but the old one stopped working"
          echo "         before orders had fetched the new pair. It caches for 10s: the window"
          echo "         has to outlast that."
        fi
        exit 1
      fi

      if login "$u0" "$p0"; then
        if [ "$u1" = "$u0" ] && [ "$p1" = "$p0" ]; then
          echo "not yet: secret/orders/db holds the same credential as before rotate.sh ran."
          echo "         Nothing was rotated."
        else
          echo "not yet: the credential from before the rotation ($u0) still logs in."
          echo "         Rotation is not finished until the old one stops working."
        fi
        exit 1
      fi

      echo "PASS — rotated under load: $ok requests, 0 failed. The new credential"
      echo "       works, and the old one is refused."
---
