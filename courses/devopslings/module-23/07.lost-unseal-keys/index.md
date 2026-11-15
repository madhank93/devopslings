---
kind: lesson
title: "OpenBao is sealed and the keys are gone"
description: |
  OpenBao restarted, sealed, and the only copy of this year's unseal keys
  went with a decommissioned laptop. The runbook points at an escrow copy.
  Try it, find out what is and is not recoverable, and get the shop's
  secrets serving again — in a way that survives the next restart.
name: lost-unseal-keys
slug: lost-unseal-keys
createdAt: "2026-11-13"

sandbox:
  stack: ha-stack
  service: ops

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      ha-reset
      bao_wipe() {
        docker exec devopslings-ha-bao sh -c 'rm -rf /openbao/file/* /openbao/file/.[!.]*' || true
        docker restart devopslings-ha-bao >/dev/null
        for _ in $(seq 60); do
          rc=0; bao status >/dev/null 2>&1 || rc=$?
          [ "$rc" = 2 ] && return 0
          sleep 0.5
        done
        echo "bao did not come back sealed" >&2
        return 1
      }
      mkdir -p /ha/bao/escrow /ha/app

      # The 2025 install. Its keys were escrowed; the cluster was later rebuilt.
      bao_wipe
      bao operator init -key-shares=3 -key-threshold=2 -format=json > /root/old-init.json
      {
        echo "OpenBao unseal keys — escrow copy, made at install (2025-02-03)."
        echo "Any two of the three unseal it."
        jq -r '.unseal_keys_b64[]' /root/old-init.json
      } > /ha/bao/escrow/unseal-keys.txt
      rm -f /root/old-init.json

      # This year's cluster, holding the shop's secrets.
      bao_wipe
      bao operator init -key-shares=3 -key-threshold=2 -format=json > /root/init.json
      for i in 0 1; do bao operator unseal "$(jq -r ".unseal_keys_b64[$i]" /root/init.json)" >/dev/null; done
      export BAO_TOKEN; BAO_TOKEN=$(jq -r .root_token /root/init.json)
      bao secrets enable -path=secret kv-v2 >/dev/null
      pw=$(head -c 18 /dev/urandom | base64 | tr -d '/+=')
      bao kv put secret/shop/db username=shop_app password="$pw" >/dev/null
      bao kv put secret/shop/payments api_key="pgw_live_$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')" >/dev/null
      psql -qX -v ON_ERROR_STOP=1 <<'SQL'
      DO $$ BEGIN
        IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'shop_app') THEN DROP OWNED BY shop_app; END IF;
      END $$;
      SQL
      PGOPTIONS="-c client_min_messages=warning" psql -qX -v ON_ERROR_STOP=1 -c "DROP ROLE IF EXISTS shop_app" \
        -c "CREATE ROLE shop_app LOGIN PASSWORD '$pw'" -c "GRANT SELECT, INSERT ON orders TO shop_app"
      unset pw BAO_TOKEN
      # The loss: the keys and root token lived on one laptop. Then a restart.
      rm -f /root/init.json /ha/app/bao-token
      docker restart devopslings-ha-bao >/dev/null
      for _ in $(seq 60); do rc=0; bao status >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] && break; sleep 0.5; done

      cat > /ha/bao/RUNBOOK.txt <<'TXT'
      OpenBao (bao:8200) — sealed after a restart

      1. Fetch the escrowed unseal keys: /ha/bao/escrow/unseal-keys.txt
      2. bao operator unseal <key>, with any two of them.

      What is in OpenBao (kv-v2, mounted at secret/):
        secret/shop/db         username, password   the shop's login to pg1, as shop_app
        secret/shop/payments   api_key              issued by the payment gateway

      The app reads its secrets with the token in /ha/app/bao-token.
      TXT
      cat > /ha/answers/lost-unseal-keys.txt <<'TXT'
      # yes or no: can the secrets stored in the sealed cluster be read again?
      old_secrets_recoverable: ?
      TXT
      echo "scenario ready — OpenBao after this morning's restart:"
      echo
      bao status 2>/dev/null | sed 's/^/  /' || true
      echo
      echo "  the runbook:   /ha/bao/RUNBOOK.txt"
      echo "  your answer:   /ha/answers/lost-unseal-keys.txt"
      echo "  the app's token goes in /ha/app/bao-token"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      status() { local rc=0; bao status >/dev/null 2>&1 || rc=$?; echo "$rc"; }
      a=$(sed -n 's/^[[:space:]]*old_secrets_recoverable[[:space:]]*:[[:space:]]*//p' /ha/answers/lost-unseal-keys.txt 2>/dev/null | head -1 | tr -d ' \t' | tr '[:upper:]' '[:lower:]' || true)
      case $a in
        no) ;;
        yes)
          echo "not yet: you answered that the old secrets can be read again. Nothing can unseal that cluster:"
          echo "         its encryption key exists only inside the storage, encrypted by a key that only a threshold"
          echo "         of its own unseal keys can rebuild. Keys from another cluster, however many, do not."
          exit 1 ;;
        *)
          echo "not yet: old_secrets_recoverable in /ha/answers/lost-unseal-keys.txt is '${a:-missing}'; answer yes or no."
          exit 1 ;;
      esac

      case $(status) in
        1) echo "not yet: OpenBao at $BAO_ADDR does not answer."; exit 1 ;;
        2)
          if bao status -format=json 2>/dev/null | jq -e '.initialized == false' >/dev/null; then
            echo "not yet: OpenBao is running but not initialised: the rebuild has not been finished."
          else
            echo "not yet: OpenBao is still sealed. The escrowed keys are from the 2025 install, a different"
            echo "         cluster — they fail with 'message authentication failed'. Without a threshold of this"
            echo "         cluster's own keys, nothing will unseal it: the data in it is gone."
          fi
          exit 1 ;;
      esac

      tok=$(tr -d ' \n' < /ha/app/bao-token 2>/dev/null || true)
      if [ -z "$tok" ]; then
        echo "not yet: OpenBao is unsealed, but /ha/app/bao-token is empty: the app has no way to read its secrets."
        exit 1
      fi
      read_db() {
        BAO_TOKEN=$tok bao kv get -format=json secret/shop/db 2>/dev/null | jq -r '.data.data.password // empty' || true
      }
      pw=$(read_db)
      if [ -z "$pw" ]; then
        echo "not yet: with the token in /ha/app/bao-token, secret/shop/db has no password field:"
        BAO_TOKEN=$tok bao kv get secret/shop/db 2>&1 | tail -2 | sed 's/^/         | /' || true
        exit 1
      fi
      if ! PGPASSWORD=$pw psql -h pg1 -U shop_app -d shop -tAXc "SELECT count(*) FROM orders" >/dev/null 2>&1; then
        echo "not yet: secret/shop/db's password does not log in to pg1 as shop_app. The old password went down"
        echo "         with the old cluster, and nobody can read it back out of Postgres either — it keeps a hash."
        echo "         Set a new password on the role, and store that one."
        exit 1
      fi
      echo "secrets serving: the app's token reads secret/shop/db, and it logs in to pg1"

      # The next restart. Unseal with whatever is in escrow now.
      docker restart devopslings-ha-bao >/dev/null
      for _ in $(seq 60); do [ "$(status)" != 1 ] && break; sleep 0.5; done
      # Each escrow file is tried on its own: one file is one set of shares.
      for f in /ha/bao/escrow/*; do
        [ -f "$f" ] || continue
        [ "$(status)" = 0 ] && break
        bao operator unseal -reset >/dev/null 2>&1 || true
        for k in $(grep -Eo '^[A-Za-z0-9+/]{43,44}=?$' "$f" || true); do
          [ "$(status)" = 0 ] && break
          bao operator unseal "$k" >/dev/null 2>&1 || true
        done
      done
      if [ "$(status)" != 0 ]; then
        bao operator unseal -reset >/dev/null 2>&1 || true
        echo "not yet: the grader restarted OpenBao, and the keys in /ha/bao/escrow/ did not unseal it."
        echo "         It is sealed again now. Escrow this cluster's keys, one per line, and test them."
        exit 1
      fi
      if [ -z "$(read_db)" ]; then
        echo "not yet: after a restart and unseal, the app's token no longer reads secret/shop/db."
        exit 1
      fi
      echo "after a restart: unsealed from escrow, and secret/shop/db still reads"
      echo
      echo "PASS — the rebuild is serving, the new keys are escrowed, and the old secrets are honestly written off."
---
