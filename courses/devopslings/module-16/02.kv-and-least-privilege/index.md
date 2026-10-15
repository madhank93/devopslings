---
kind: lesson
title: "One token reads every secret"
description: |
  billing, orders and shipping each keep their config in OpenBao, and all
  three log in with the same token, whose policy covers all of secret/. A bug
  in shipping is a leak of billing's payment key. Give each service a policy
  for its own path and a token of its own, and prove the other paths are
  denied.
name: kv-and-least-privilege
slug: kv-and-least-privilege
createdAt: "2026-10-14"

sandbox:
  stack: ci-stack
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 600
    run: |
      L=../../courses/devopslings/module-16/02.kv-and-least-privilege
      G=$L/kv.compose.yaml
      dc() { docker compose -f compose.yaml -f "$G" "$@"; }
      bao() { dc exec -T -e BAO_TOKEN=devopslings-root bao bao "$@"; }

      bao kv put secret/billing/config payments_key=pgw_live_7c1e5a9d03b84f62ae17 >/dev/null
      bao kv put secret/orders/config db_password=ord-3f9a61c2e8d7 >/dev/null
      bao kv put secret/shipping/config carrier_token=crr_live_52d8e0b7a1c94f36 >/dev/null

      # Policies from an earlier attempt would be graded as the student's.
      for p in billing orders shipping; do
        bao policy delete "$p" >/dev/null 2>&1 || true
      done

      # The policy everyone copies from a tutorial: the whole engine, every verb.
      printf '%s\n' 'path "secret/*" {' \
        '  capabilities = ["create", "read", "update", "delete", "list"]' '}' \
        | bao policy write apps - >/dev/null
      shared=$(bao token create -policy=apps -field=token | tr -d '\r')

      # .env is the student's file and outlives `compose down`, so it is reset
      # here. COMPOSE_FILE layers the services over the stack.
      cat > .env <<ENV
      COMPOSE_FILE=compose.yaml:$G
      COMPOSE_PROJECT_NAME=devopslings-ci-stack
      BILLING_BAO_TOKEN=$shared
      ORDERS_BAO_TOKEN=$shared
      SHIPPING_BAO_TOKEN=$shared
      ENV

      dc up -d --build --force-recreate billing orders shipping >/dev/null 2>&1
      for port in 18165 18166 18167; do
        for _ in $(seq 40); do
          curl -fsS --max-time 2 "http://127.0.0.1:$port/health" >/dev/null 2>&1 && break
          sleep 0.5
        done
        curl -sS --max-time 2 "http://127.0.0.1:$port/health" || true
      done

      echo
      echo "scenario ready — three services, one token, policy 'apps' on secret/*."
      echo "  tokens:   sandboxes/ci-stack/.env"
      echo "  OpenBao:  http://localhost:8200/ui   (token: devopslings-root)"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      L=../../courses/devopslings/module-16/02.kv-and-least-privilege
      G=$L/kv.compose.yaml
      dc() { docker compose -f compose.yaml -f "$G" "$@"; }
      bao() { dc exec -T -e BAO_TOKEN=devopslings-root bao bao "$@"; }
      as() { local t=$1; shift; dc exec -T -e BAO_TOKEN="$t" bao bao "$@"; }
      services="billing orders shipping"
      tok() { local v="tok_$1"; printf '%s' "${!v}"; }
      port_of() { case $1 in billing) echo 18165 ;; orders) echo 18166 ;; shipping) echo 18167 ;; esac; }
      policies_of() {
        bao token lookup -format=json "$1" 2>/dev/null | tr -d ' \r\n' \
          | sed -n 's/.*[{,]"policies":\[\([^]]*\)\].*/\1/p' | tr -d '"' || true
      }
      caps() { bao token capabilities "$1" "$2" 2>/dev/null | tr -d '\r' || true; }

      for s in $services; do
        ctr=$(dc ps -q --status running "$s" 2>/dev/null || true)
        if [ -z "$ctr" ]; then
          echo "not yet: $s is not running. From sandboxes/ci-stack: docker compose up -d"
          exit 1
        fi
        t=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$ctr" \
                    | sed -n 's/^BAO_TOKEN=//p' || true)
        var=$(printf '%s' "$s" | tr '[:lower:]' '[:upper:]')_BAO_TOKEN
        want=$(grep -E "^$var=" .env 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
        printf -v "tok_$s" '%s' "$t"
        if [ "$t" != "$want" ]; then
          echo "not yet: $s is still running with the token it was created with, and .env"
          echo "         now says something else. compose reads .env when it creates a"
          echo "         container: docker compose up -d"
          exit 1
        fi
      done

      # Each token is real, scoped, and its own.
      for s in $services; do
        pol=$(policies_of "$(tok "$s")")
        if [ -z "$pol" ]; then
          echo "not yet: $s's token is not a valid OpenBao token (expired, revoked or mistyped)."
          exit 1
        fi
        if printf ',%s,' "$pol" | grep -q ',root,'; then
          echo "not yet: $s runs with a root token. Any bug in $s can now read, change or"
          echo "         delete every secret in OpenBao, and create more root tokens."
          exit 1
        fi
      done
      for a in $services; do
        for b in $services; do
          if [ "$a" \< "$b" ] && [ "$(tok "$a")" = "$(tok "$b")" ]; then
            echo "not yet: $a and $b run with the same token. Whatever one may read, so may"
            echo "         the other, and revoking it takes both down. One token per service."
            exit 1
          fi
        done
      done

      # Each service can still do its job: read its own config.
      for s in $services; do
        own="secret/data/$s/config"
        if ! curl -fsS --max-time 5 "http://127.0.0.1:$(port_of "$s")/health" >/dev/null 2>&1; then
          said=$(curl -sS --max-time 5 "http://127.0.0.1:$(port_of "$s")/health" 2>&1 || true)
          if caps "$(tok "$s")" "secret/$s/config" | grep -qw read; then
            echo "not yet: $s cannot read its own config. Its policy grants read on"
            echo "         secret/$s/config, but secret/ is KV version 2, and the API serves the"
            echo "         data at $own. Policies match API paths, not CLI paths."
          else
            echo "not yet: $s cannot read its own config: ${said%$'\n'}"
            echo "         Its token's policies: $(policies_of "$(tok "$s")"); on $own it has: $(caps "$(tok "$s")" "$own")"
          fi
          exit 1
        fi
      done

      # The wrong paths are denied, and proven: the read is attempted with each
      # service's own token, against a secret that exists.
      proof=""
      for s in $services; do
        for o in $services; do
          [ "$s" = "$o" ] && continue
          if out=$(as "$(tok "$s")" kv get "secret/$o/config" 2>&1); then
            echo "not yet: $s's token can read secret/$o/config. Its policies: $(policies_of "$(tok "$s")")."
            echo "         A path like secret/* or secret/data/* covers every service's secrets."
            exit 1
          fi
          if ! printf '%s' "$out" | grep -q 'permission denied'; then
            echo "not yet: reading secret/$o/config with $s's token failed, but not with"
            echo "         'permission denied': $(printf '%s' "$out" | tr -d '\r' | grep -v '^$' | tail -1)"
            exit 1
          fi
          proof="$proof
        denied: $s -> secret/$o/config (403 permission denied)"
        done
      done

      # And on its own path, read is all it gets.
      for s in $services; do
        extra=$(caps "$(tok "$s")" "secret/data/$s/config" | tr ',' '\n' | tr -d ' ' \
                  | grep -vxE 'read|list' | tr '\n' ' ' || true)
        if [ -n "$extra" ]; then
          echo "not yet: $s's token can also ${extra% } its own secret. $s only reads"
          echo "         its config, so a bug or a stolen token could rewrite it. Grant read only."
          exit 1
        fi
      done

      echo "PASS — one token per service, each reads only its own config, and every"
      echo "       other path was tried and refused:$proof"
---
