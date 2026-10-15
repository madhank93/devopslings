---
kind: lesson
title: "Find every secret the inventory service has left lying around"
description: |
  Before anyone moves the inventory service's secrets into a vault, someone has
  to know where they all are. Audit its estate: the repo, its CI settings, its
  image, its running container, the registry. List every secret you find, and
  nothing that only looks like one.
name: secret-sprawl-audit
slug: secret-sprawl-audit
createdAt: "2026-10-14"

sandbox:
  stack: ci-stack
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 600
    run: |
      api="http://127.0.0.1:3000/api/v1"
      auth="-u devops:devopslings"
      repo="devops/inventory"
      here="${DEVOPSLINGS_ROOT}/scratch/secret-sprawl-audit"
      image="127.0.0.1:5000/inventory/api:1.4"
      ctr=devopslings-inventory-api

      # ---- clean slate ------------------------------------------------------------
      # The repo is recreated rather than reset: its CI variables and run
      # history go with it.
      docker rm -f "$ctr" >/dev/null 2>&1 || true
      curl -fsS $auth -X DELETE "${api}/repos/${repo}" >/dev/null 2>&1 || true
      curl -fsS $auth -X POST "${api}/user/repos" -H 'Content-Type: application/json' \
        -d '{"name":"inventory","auto_init":false,"default_branch":"main","private":false}' >/dev/null

      rm -rf "$here"
      mkdir -p "$here/answers"
      cat > "$here/answers/secrets.txt" <<'TXT'
      # One secret value per line, exactly as it appears where you found it.
      # Lines starting with # are ignored. Put where you found it in a comment.
      TXT

      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT

      # ---- the repo, commit by commit ---------------------------------------------
      mkdir -p "$work/r" && cd "$work/r"
      git init -q -b main
      git config user.email ops@example.invalid
      git config user.name ops
      mkdir -p deploy tests/fixtures app

      cat > README.md <<'MD'
      # inventory

      Stock levels for the shop. Ships as `registry:5000/inventory/api`.
      Copy `deploy/inventory.ini.example` to `deploy/inventory.ini` to run it.
      MD
      cat > deploy/inventory.ini.example <<'INI'
      [smtp]
      host = smtp.example.invalid
      user = inventory
      smtp_password = changeme
      INI
      cat > deploy/deploy_ed25519.pub <<'PUB'
      ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK3vQm8d1Zr6c0pXn2b7Yw4e9TqLs5HfJ0aUoR1xVg2N deploy@inventory
      PUB
      cat > tests/fixtures/fake.env <<'ENV'
      # Fixture for the config loader tests. Not a real key.
      LEDGER_API_KEY=lgr_test_0000000000000000
      ENV
      git add -A && git commit -qm "inventory service skeleton"

      cat > .env <<'ENV'
      LEDGER_API_KEY=lgr_prod_4e1b9c07d2a85f36e0b7
      ENV
      git add -A && git commit -qm "local env for the ledger sync"

      git rm -q .env
      printf '.env\napp/signing.key\n' > .gitignore
      git add -A && git commit -qm "remove .env, ignore it"

      cat > deploy/inventory.ini <<'INI'
      [smtp]
      host = smtp.example.invalid
      user = inventory
      smtp_password = Halyard-mq7-Vesper-22
      INI
      cat > app/start.sh <<'SH'
      #!/bin/sh
      echo "inventory-api ${BUILD_SHA:-dev} listening on :${APP_PORT}"
      while :; do sleep 3600; done
      SH
      chmod +x app/start.sh
      cat > Dockerfile <<'DOCKER'
      FROM busybox:1.36.1
      ENV APP_PORT=8080
      COPY app/signing.key /app/signing.key
      RUN sha256sum /app/signing.key > /app/assets.sig && rm /app/signing.key
      COPY app/start.sh /app/start.sh
      CMD ["/app/start.sh"]
      DOCKER
      git add -A && git commit -qm "deploy config and image"
      git push -q "http://devops:devopslings@127.0.0.1:3000/${repo}.git" main

      # ---- CI settings ------------------------------------------------------------
      # A variable is plaintext to anyone who can open the repo settings; a
      # secret is write-only.
      curl -fsS $auth -X POST "${api}/repos/${repo}/actions/variables/NOTIFY_WEBHOOK_TOKEN" \
        -H 'Content-Type: application/json' -d '{"value":"nwh_8c3f02d9b6a14e7f5d21"}' >/dev/null
      curl -fsS $auth -X POST "${api}/repos/${repo}/actions/variables/INVENTORY_REGION" \
        -H 'Content-Type: application/json' -d '{"value":"eu-west-1"}' >/dev/null
      curl -fsS $auth -X PUT "${api}/repos/${repo}/actions/secrets/DEPLOY_SSH_KEY" \
        -H 'Content-Type: application/json' -d '{"data":"write-only: no API returns this value"}' >/dev/null

      # ---- the image: the key is deleted, in a later layer ------------------------
      printf 'isk_1f9a7d3e60b24c8895ce0d17\n' > app/signing.key
      docker build -q -t "$image" . >/dev/null
      docker push -q "$image" >/dev/null

      # ---- the running container ---------------------------------------------------
      docker run -d --name "$ctr" --init --network none \
        -e DB_PASSWORD=Tarn-oxide-5590-quill \
        -e BUILD_SHA=23f7dd08e78ac89fee2169e5ebc99f264394f93f \
        "$image" >/dev/null

      # ---- the log line: a token in a URL, in the registry's access log ----------
      curl -s -o /dev/null "http://127.0.0.1:5000/v2/inventory/api/tags/list?access_token=rlt_c41e9b7a2f6d083e5b" || true

      echo "scenario ready — the inventory service's estate:"
      echo
      echo "  repo        http://localhost:3000/devops/inventory   (devops / devopslings)"
      echo "  image       ${image}"
      echo "  container   ${ctr}"
      echo "  registry    http://localhost:5000, and the logs of the stack's registry container"
      echo
      echo "  answer:     ${here}/answers/secrets.txt"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 60
    run: |
      ans="${DEVOPSLINGS_ROOT}/scratch/secret-sprawl-audit/answers/secrets.txt"
      if [ ! -f "$ans" ]; then
        echo "not yet: ${ans} is missing — reset the lesson to get the template back"
        exit 1
      fi

      # value|where, one per planted secret.
      planted="Halyard-mq7-Vesper-22|a config file on main
      lgr_prod_4e1b9c07d2a85f36e0b7|the repo's history
      nwh_8c3f02d9b6a14e7f5d21|the CI settings
      Tarn-oxide-5590-quill|the running container
      isk_1f9a7d3e60b24c8895ce0d17|the image
      rlt_c41e9b7a2f6d083e5b|a log"

      # substring|why it is not a secret
      decoys="changeme|it is the placeholder in inventory.ini.example
      lgr_test_0000000000000000|it is a test fixture, and the file says it is not a real key
      AAAAC3NzaC1lZDI1NTE5AAAAIK3vQm8d|it is a public key; the private half is the secret, and it is not here
      a638994be15f6afbfdcdc757f7874630|it is a sha256 of the signing key; a hash does not give you the key
      23f7dd08e78ac89fee2169e5ebc99f264394f93f|it is BUILD_SHA, a commit id, public by design
      eu-west-1|it is a region name
      devopslings|it is the sandbox's login, from the lesson text, not the inventory service's
      dpl_9f3c1a7e5b2d4086af11c7e390bb42d1|it belongs to devops/checkout, which is outside this audit"

      found=""
      bad=0
      fp=0
      while IFS= read -r line || [ -n "$line" ]; do
        line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        case "$line" in ''|'#'*) continue ;; esac

        hit=$(printf '%s\n' "$planted" | sed 's/^[[:space:]]*//' | awk -F'|' -v v="$line" '$1==v{print $2}')
        if [ -n "$hit" ]; then
          found="${found}${hit}
      "
          continue
        fi
        part=$(printf '%s\n' "$planted" | sed 's/^[[:space:]]*//' | awk -F'|' -v v="$line" 'index(v,$1){print $1}' | head -1)
        if [ -n "$part" ]; then
          echo "not yet: the line '${line}' contains a secret, and is more than it."
          echo "         Write the value alone on its line, exactly as you found it: ${part%"${part#????}"}…"
          bad=1
          continue
        fi
        why=$(printf '%s\n' "$decoys" | sed 's/^[[:space:]]*//' | awk -F'|' -v v="$line" 'index(v,$1){print $2}' | head -1)
        if [ -n "$why" ]; then
          echo "not yet: '${line}' does not belong on the list: ${why}."
        else
          echo "not yet: '${line}' is not one of the secrets in this estate."
        fi
        bad=1
        fp=1
      done < "$ans"
      if [ "$fp" = 1 ]; then
        echo "         An audit that lists everything is as useless as one that lists nothing: each false"
        echo "         positive is a rotation someone will do for no reason."
      fi
      if [ "$bad" = 1 ]; then
        exit 1
      fi

      total=$(printf '%s\n' "$planted" | grep -c '|' || true)
      places=$(printf '%s' "$found" | sed 's/^[[:space:]]*//' | grep -v '^$' | sort -u || true)
      n=$(printf '%s\n' "$places" | grep -c . || true)
      if [ "${n:-0}" -lt "$total" ]; then
        echo "not yet: ${n:-0} of the ${total} secrets in the inventory estate are on your list."
        if [ "${n:-0}" -gt 0 ]; then
          echo "         You have found one in: $(printf '%s\n' "$places" | paste -sd ',' - | sed 's/,/, /g')."
        fi
        # Say which kind of place is still unread, without naming it.
        plain=0
        for p in "a config file on main" "the CI settings" "the running container"; do
          printf '%s\n' "$places" | grep -qxF "$p" || plain=1
        done
        if [ "$plain" = 1 ]; then
          echo "         At least one of the missing ones is in plain view today, to anyone who opens the right page."
        else
          echo "         The rest are where nobody looks today: what the estate used to contain, and what"
          echo "         its tools wrote down on the way past."
        fi
        exit 1
      fi

      echo "PASS — all ${total} secrets found, and nothing listed that is not one."
---
