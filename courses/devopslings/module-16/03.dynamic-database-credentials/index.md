---
kind: lesson
title: "Four services share one database password"
description: |
  billing, orders, shipping and reports all log in to Postgres as `app`, with
  one password kept in OpenBao. When one of them leaks it, the only way to
  shut the leak is to change the password, and that takes all four down. Give
  each service a credential of its own, issued by OpenBao with a lease, so
  revoking one cuts off exactly one service.
name: dynamic-database-credentials
slug: dynamic-database-credentials
createdAt: "2026-10-14"

sandbox:
  stack: ci-stack
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 600
    run: |
      L=../../courses/devopslings/module-16/03.dynamic-database-credentials
      G=$L/services.compose.yaml
      dc() { docker compose -f compose.yaml -f "$G" "$@"; }
      bao() { dc exec -T -e BAO_TOKEN=devopslings-root bao bao "$@"; }
      psql() { dc exec -T db psql -U postgres -d app -v ON_ERROR_STOP=1 -qAt "$@"; }
      services="billing orders shipping reports"

      # An earlier attempt's engine and the roles it issued would be graded
      # as this one's. Force, because a broken revocation must not block reset.
      bao lease revoke -force -prefix database/ >/dev/null 2>&1 || true
      bao secrets disable database >/dev/null 2>&1 || true

      psql >/dev/null <<'SQL'
      DO $$
      DECLARE r text;
      BEGIN
        FOR r IN SELECT rolname FROM pg_roles WHERE rolname LIKE 'v-%' LOOP
          EXECUTE format('DROP ROLE %I', r);
        END LOOP;
      END $$;
      DROP TABLE IF EXISTS ledger;
      DROP ROLE IF EXISTS app;
      DROP ROLE IF EXISTS bao;
      DROP ROLE IF EXISTS app_rw;

      CREATE TABLE ledger (id serial PRIMARY KEY, service text, amount_cents int);
      INSERT INTO ledger (service, amount_cents)
        VALUES ('billing', 1200), ('orders', 3400), ('shipping', 560), ('reports', 0);

      -- What every service needs, as a group role to grant.
      CREATE ROLE app_rw NOLOGIN;
      GRANT SELECT, INSERT ON ledger TO app_rw;
      GRANT USAGE ON SEQUENCE ledger_id_seq TO app_rw;

      -- The shared login all four services use today.
      CREATE ROLE app LOGIN PASSWORD 'Shr3d-pg-2019' IN ROLE app_rw;

      -- The account OpenBao manages roles with: it can create logins, hand
      -- them app_rw, and end their sessions. It is not a superuser.
      CREATE ROLE bao LOGIN CREATEROLE PASSWORD 'bao-admin-pw';
      GRANT app_rw TO bao WITH ADMIN OPTION;
      GRANT pg_signal_backend TO bao;
      SQL

      bao kv put secret/shared/db username=app password=Shr3d-pg-2019 >/dev/null

      # Each service has its own token already. It may read the shared secret,
      # and the database role named after the service, once one exists.
      {
        echo "COMPOSE_FILE=compose.yaml:$G"
        echo "COMPOSE_PROJECT_NAME=devopslings-ci-stack"
      } > .env.new
      for s in $services; do
        printf '%s\n' 'path "secret/data/shared/db" {' '  capabilities = ["read"]' '}' \
          "path \"database/creds/$s\" {" '  capabilities = ["read"]' '}' \
          | bao policy write "svc-$s" - >/dev/null
        t=$(bao token create -policy="svc-$s" -field=token | tr -d '\r')
        S=$(printf '%s' "$s" | tr '[:lower:]' '[:upper:]')
        echo "${S}_BAO_TOKEN=$t" >> .env.new
        echo "${S}_DB_CREDS=secret/data/shared/db" >> .env.new
      done
      # .env is the student's file and outlives `compose down`, so it is reset.
      mv .env.new .env

      dc up -d --build --force-recreate $services >/dev/null 2>&1
      for port in 18161 18162 18163 18164; do
        for _ in $(seq 40); do
          curl -fsS --max-time 3 "http://127.0.0.1:$port/health" >/dev/null 2>&1 && break
          sleep 0.5
        done
        curl -sS --max-time 5 "http://127.0.0.1:$port/health" | grep -E '^(service|user)=' | tr '\n' ' ' || true
        echo
      done

      echo
      echo "scenario ready — four services, one Postgres login: app."
      echo "  config:   sandboxes/ci-stack/.env   (*_DB_CREDS is where each service reads)"
      echo "  OpenBao:  http://localhost:8200/ui  (token: devopslings-root)"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      L=../../courses/devopslings/module-16/03.dynamic-database-credentials
      G=$L/services.compose.yaml
      dc() { docker compose -f compose.yaml -f "$G" "$@"; }
      bao() { dc exec -T -e BAO_TOKEN=devopslings-root bao bao "$@"; }
      psql() { dc exec -T db psql -U postgres -d app -qAt "$@"; }
      services="billing orders shipping reports"
      port_of() {
        case $1 in billing) echo 18161 ;; orders) echo 18162 ;; shipping) echo 18163 ;; reports) echo 18164 ;; esac
      }
      health() { curl -sS --max-time 8 "http://127.0.0.1:$(port_of "$1")/health" 2>/dev/null || true; }
      field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1 || true; }
      wait_health() {
        local b=""
        for _ in $(seq 40); do
          b=$(health "$1")
          case "$b" in *service=*) break ;; esac
          sleep 0.5
        done
        printf '%s' "$b"
      }

      for s in $services; do
        if [ -z "$(dc ps -q --status running "$s" 2>/dev/null || true)" ]; then
          echo "not yet: $s is not running. From sandboxes/ci-stack: docker compose up -d"
          exit 1
        fi
      done

      # Each service fetches its credential once, at its first request. Fresh
      # containers grade the configuration as it is now, not as it was.
      dc up -d --force-recreate --no-deps $services >/dev/null 2>&1

      users=""
      for s in $services; do
        b=$(wait_health "$s")
        src=$(field "$b" source); user=$(field "$b" user); lease=$(field "$b" lease); err=$(field "$b" error)
        printf -v "user_$s" '%s' "$user"
        printf -v "lease_$s" '%s' "$lease"
        if [ -z "$b" ]; then
          echo "not yet: $s does not answer on :$(port_of "$s")/health. See: docker compose logs $s"
          exit 1
        fi
        if [ -n "$err" ]; then
          case "$err" in
            *"OpenBao refused"*"permission denied"*)
              echo "not yet: $s may not read $src. Its token may read database/creds/$s"
              echo "         and secret/data/shared/db. Name each database role after its service." ;;
            *"OpenBao refused"*)
              echo "not yet: $s could not get a credential from $src:"
              echo "         $err" ;;
            *"permission denied for table"*)
              echo "not yet: $s logs in but cannot read the ledger table. Its role's"
              echo "         creation_statements make a login and grant it nothing. Grant it app_rw."
              echo "         (Roles already issued keep what they were created with: restart $s.)" ;;
            *)
              echo "not yet: $s cannot use the database as ${user:-?}:"
              echo "         $err" ;;
          esac
          exit 1
        fi
        users="$users $user"
      done

      # Each credential must be its own, and leased.
      if [ "$(printf '%s\n' $users | sort -u | wc -l | tr -d ' ')" = 1 ]; then
        echo "not yet: all four services log in as '$user_billing'. However often that password"
        echo "         changes, it is one password in four places: one leak exposes all four,"
        echo "         and revoking it stops all four."
        exit 1
      fi
      for s in $services; do
        u="user_$s"; l="lease_$s"
        if [ -z "${!l}" ]; then
          echo "not yet: $s's credential (${!u}) has no lease. It is a static secret from"
          echo "         $(field "$(health "$s")" source): nothing expires it, and nothing can"
          echo "         revoke it except changing the password by hand."
          exit 1
        fi
        case "${!l}" in
          "database/creds/$s/"*) ;;
          *)
            echo "not yet: $s's lease is ${!l}. Give each service its own role, so a lease's"
            echo "         path says whose it is: database/creds/$s/…"
            exit 1 ;;
        esac
      done

      # Revoke one lease. Exactly that service must lose the database.
      if ! out=$(bao lease revoke -sync "$lease_orders" 2>&1); then
        why=$(printf '%s' "$out" | tr -d '\r' | grep -E '^\* ' | head -1 || true)
        echo "not yet: OpenBao could not revoke orders's lease:"
        echo "         ${why:-$(printf '%s' "$out" | tr -d '\r' | tail -1)}"
        if [ -z "$(bao read -field=revocation_statements database/roles/orders 2>/dev/null | tr -d '[]\r\n ' || true)" ]; then
          echo "         The orders role has no revocation_statements, so OpenBao runs its default,"
          echo "         which revokes privileges object by object. Say exactly what to undo."
        fi
        dc up -d --force-recreate --no-deps orders >/dev/null 2>&1 || true
        exit 1
      fi
      for s in $services; do
        b=$(health "$s"); err=$(field "$b" error)
        if [ "$s" = orders ] && [ -z "$err" ]; then
          if [ -n "$(psql -c "SELECT 1 FROM pg_roles WHERE rolname = '$user_orders'" 2>/dev/null | tr -d '\r' || true)" ]; then
            echo "not yet: OpenBao revoked orders's lease, but its Postgres role still exists"
            echo "         and still logs in ($user_orders)."
            echo "         The role's revocation_statements must remove it."
          else
            echo "not yet: orders's lease is revoked and its role is gone, yet orders still"
            echo "         reaches the database. It is not using the credential it reports."
          fi
          dc up -d --force-recreate --no-deps orders >/dev/null 2>&1 || true
          exit 1
        fi
        if [ "$s" != orders ] && [ -n "$err" ]; then
          echo "not yet: revoking orders's lease also cut off $s:"
          echo "         $err"
          echo "         Revocation must touch only the lease's own role."
          dc up -d --force-recreate --no-deps $services >/dev/null 2>&1 || true
          exit 1
        fi
      done

      # Give orders a fresh credential, as a restart would in real life.
      dc up -d --force-recreate --no-deps orders >/dev/null 2>&1
      wait_health orders >/dev/null

      echo "PASS — four services, four leased credentials. Revoking orders's lease cut off"
      echo "       orders ($user_orders) and nothing else."
---
