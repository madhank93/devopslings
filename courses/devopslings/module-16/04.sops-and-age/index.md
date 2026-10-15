---
kind: lesson
title: "Put the secrets in git, encrypted, where CI can read them"
description: |
  The deploy needs three secrets and they live in a plaintext file on one
  laptop. Move them into the repository, encrypted with sops and age, so the
  pipeline can decrypt them with a key of its own. The plaintext never touches
  git, not even for one commit.
name: sops-and-age
slug: sops-and-age
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
      repo="devops/checkout"
      remote="http://devops:devopslings@127.0.0.1:3000/${repo}.git"
      here="${DEVOPSLINGS_ROOT}/scratch/sops-and-age"

      # ---- clean slate ------------------------------------------------------------
      for rule in $(curl -fsS $auth "${api}/repos/${repo}/branch_protections" 2>/dev/null \
                      | tr ',' '\n' | sed -n 's/.*"rule_name":"\([^"]*\)".*/\1/p' \
                      | sed 's/%/%25/g; s/ /%20/g; s/\*/%2A/g; s/?/%3F/g; s/\[/%5B/g; s/]/%5D/g; s|/|%2F|g' || true); do
        curl -fsS $auth -X DELETE "${api}/repos/${repo}/branch_protections/${rule}" >/dev/null 2>&1 || true
      done
      curl -fsS $auth -X DELETE "${api}/repos/${repo}/actions/secrets/SOPS_AGE_KEY" >/dev/null 2>&1 || true

      # ---- the plaintext, on "the laptop" -----------------------------------------
      rm -rf "$here"
      mkdir -p "$here"
      cat > "$here/secrets.env" <<'ENV'
      DB_PASSWORD=velvet-Orchard-4417-quay
      PAYMENTS_API_KEY=pgw_live_7c1e0a9f4b3d2e68a5
      SESSION_SECRET=3f9d1c7ab2e04f6d8a51c9e7b0d2f4a6
      ENV

      # ---- the repo ----------------------------------------------------------------
      # A fresh root commit, and only main: the check reads every commit on
      # every ref, so nothing from an earlier attempt may survive a reset.
      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT
      git clone -q "$remote" "$work/c"
      cd "$work/c"
      git config user.email devops@example.invalid
      git config user.name devops
      for ref in $(git ls-remote "$remote" | awk '{print $2}' | grep -v -e '^HEAD$' -e '^refs/heads/main$' -e '^refs/pull/' || true); do
        git push -q origin ":${ref}" 2>/dev/null || true
      done
      git checkout -q --orphan fresh
      git rm -rq --cached . >/dev/null 2>&1 || true
      git clean -fdq
      mkdir -p scripts deploy .forgejo/workflows

      cat > scripts/deploy.sh <<'SH'
      #!/bin/sh
      # Pretends to deploy. Decrypts deploy/secrets.enc.env with the identity in
      # SOPS_AGE_KEY and prints which identity that was, and a fingerprint of
      # each value: enough to prove the right secrets arrived, useless to a
      # reader of the log.
      set -eu
      f=deploy/secrets.enc.env

      if [ -z "${SOPS_AGE_KEY:-}" ]; then
        echo "FATAL: SOPS_AGE_KEY is not set"
        exit 1
      fi
      echo "ci identity: $(printf '%s\n' "$SOPS_AGE_KEY" | age-keygen -y | head -1)"

      if [ ! -f "$f" ]; then
        echo "FATAL: $f is not in the repo"
        exit 1
      fi
      plain=$(mktemp)
      trap 'rm -f "$plain"' EXIT
      if ! sops --disable-version-check -d "$f" > "$plain"; then
        echo "FATAL: sops could not decrypt $f with this identity"
        exit 1
      fi
      for k in DB_PASSWORD PAYMENTS_API_KEY SESSION_SECRET; do
        v=$(sed -n "s/^$k=//p" "$plain")
        if [ -z "$v" ]; then
          echo "FATAL: $k is not in $f"
          exit 1
        fi
        echo "$k fingerprint=$(printf '%s' "$v" | sha256sum | cut -c1-12)"
      done
      echo "deployed ok"
      SH

      cat > .forgejo/workflows/deploy.yml <<'YAML'
      name: deploy

      on: [push, workflow_dispatch]

      jobs:
        deploy:
          runs-on: docker
          container:
            image: devopslings-ci-sops:3.10.2
          steps:
            - run: git clone -q http://forge:3000/devops/checkout.git . && git checkout -q ${{ github.sha }}
            - run: sh scripts/deploy.sh
              env:
                SOPS_AGE_KEY: ${{ secrets.SOPS_AGE_KEY }}
      YAML

      cat > README.md <<'MD'
      # checkout

      The deploy reads its secrets from `deploy/secrets.enc.env`, a sops file
      encrypted with age. CI decrypts it with the identity in the
      `SOPS_AGE_KEY` repository secret.
      MD

      touch deploy/.gitkeep
      git add -A
      git commit -qm "deploy reads sops-encrypted secrets"
      git push -q origin fresh:main --force

      echo "scenario ready — the plaintext is at ${here}/secrets.env"
      echo
      echo "  http://localhost:3000/devops/checkout   (devops / devopslings)"
      echo "  sops and age: on your machine, or 'docker compose -p devopslings-ci-stack exec sops sh' in sandboxes/ci-stack"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 600
    run: |
      api="http://127.0.0.1:3000/api/v1"
      auth="-u devops:devopslings"
      repo="devops/checkout"
      f=deploy/secrets.enc.env

      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT
      git clone -q "http://devops:devopslings@127.0.0.1:3000/${repo}.git" "$work/c"
      cd "$work/c"
      git fetch -q origin '+refs/*:refs/remotes/all/*' 2>/dev/null || true

      # ---- 1. plaintext never, on any ref, in any commit --------------------------
      # name:value:fingerprint, the fingerprint being sha256(value)[:12].
      for row in "DB_PASSWORD:velvet-Orchard-4417-quay:3960cc1656f6" \
                 "PAYMENTS_API_KEY:pgw_live_7c1e0a9f4b3d2e68a5:4b0ef3f898fd" \
                 "SESSION_SECRET:3f9d1c7ab2e04f6d8a51c9e7b0d2f4a6:2a54041f71db"; do
        name=${row%%:*}; rest=${row#*:}; value=${rest%%:*}
        hit=$(git log --all --format=%h -S"$value" 2>/dev/null | tail -1 || true)
        if [ -n "$hit" ]; then
          echo "not yet: the plaintext value of ${name} was committed, in ${hit}."
          if git grep -qF "$value" HEAD -- 2>/dev/null; then
            echo "         It is on main right now."
          else
            echo "         It is gone from main, and history still has it: every clone does."
            echo "         Reset the lesson, or rewrite the history (module 08), and encrypt before the first commit."
          fi
          exit 1
        fi
      done
      key=$(git log --all --format=%h -SAGE-SECRET-KEY-1 2>/dev/null | tail -1 || true)
      if [ -n "$key" ]; then
        echo "not yet: an age private key was committed, in ${key}."
        echo "         Anyone who can clone the repo can now decrypt every file encrypted to it."
        exit 1
      fi

      # ---- 2. ciphertext on main --------------------------------------------------
      if [ ! -f "$f" ]; then
        echo "not yet: ${f} is not on main — the deploy reads the secrets from there"
        exit 1
      fi
      if ! grep -q '^sops_mac=ENC\[' "$f"; then
        echo "not yet: ${f} is not a sops file — it has no sops_mac line."
        echo "         Encrypt it with sops; an encoding such as base64 is not encryption."
        exit 1
      fi
      clear=$(grep -v -e '^sops_' -e '^#' -e '^[[:space:]]*$' "$f" | grep -v '=ENC\[AES256_GCM,' | cut -d= -f1 | tr '\n' ' ' || true)
      if [ -n "$clear" ]; then
        echo "not yet: ${f} has values sops did not encrypt: ${clear}"
        exit 1
      fi
      recips=$(sed -n 's/^sops_age__list_[0-9]*__map_recipient=//p' "$f" | sort -u)
      if [ -z "$recips" ]; then
        echo "not yet: ${f} is not encrypted to any age key — CI decrypts with age"
        exit 1
      fi
      root=$(git rev-list --max-parents=0 HEAD | tail -1)
      if ! git diff --quiet "$root" HEAD -- scripts/deploy.sh; then
        echo "not yet: scripts/deploy.sh has changed — the check reads what it prints. Put it back."
        exit 1
      fi

      # ---- 3. CI decrypts it ------------------------------------------------------
      # The check starts its own run, so it grades the SOPS_AGE_KEY secret as it
      # is now, not as it was at the last push.
      last=$(curl -fsS $auth "${api}/repos/${repo}/actions/tasks?limit=50" 2>/dev/null \
               | tr '{' '\n' | sed -n 's/^"id":\([0-9]*\),.*/\1/p' | sort -n | tail -1 || true)
      d=$(curl -s -o /dev/null -w '%{http_code}' $auth -X POST \
            "${api}/repos/${repo}/actions/workflows/deploy.yml/dispatches" \
            -H 'Content-Type: application/json' -d '{"ref":"main"}' 2>/dev/null || true)
      if [ "$d" != 204 ]; then
        echo "not yet: could not start .forgejo/workflows/deploy.yml on main (HTTP ${d})."
        echo "         The check runs the deploy itself: keep the file, and keep workflow_dispatch in its on: list."
        exit 1
      fi
      run=""
      state=""
      for _ in $(seq 60); do
        row=$(curl -fsS $auth "${api}/repos/${repo}/actions/tasks?limit=50" 2>/dev/null \
                | tr '{' '\n' | grep '"event":"workflow_dispatch"' | head -1 || true)
        id=$(printf '%s' "$row" | sed -n 's/^"id":\([0-9]*\),.*/\1/p')
        if [ -n "$id" ] && [ "$id" -gt "${last:-0}" ]; then
          run=$(printf '%s' "$row" | sed -n 's/.*"run_number":\([0-9]*\).*/\1/p')
          state=$(printf '%s' "$row" | sed -n 's/.*"status":"\([a-z]*\)".*/\1/p')
          case "$state" in success|failure|cancelled|skipped) break ;; esac
        fi
        sleep 3
      done
      if [ -z "$run" ]; then
        echo "not yet: the deploy run the check started never appeared — is the runner up?"
        exit 1
      fi
      logs=$(curl -fsS $auth "http://127.0.0.1:3000/${repo}/actions/runs/${run}/jobs/0/logs" 2>/dev/null || true)
      ci=$(printf '%s\n' "$logs" | sed -n 's/.*ci identity: \(age1[a-z0-9]*\).*/\1/p' | head -1)

      case "$logs" in
        *"SOPS_AGE_KEY is not set"*)
          echo "not yet: there is no SOPS_AGE_KEY secret on the repo, so CI has no key to decrypt with."
          exit 1 ;;
      esac
      if [ -z "$ci" ]; then
        echo "not yet: run #${run} could not derive a public key from SOPS_AGE_KEY."
        echo "         The secret must hold an age identity: the AGE-SECRET-KEY-1... line age-keygen writes."
        exit 1
      fi
      if ! printf '%s\n' "$recips" | grep -qx "$ci"; then
        echo "not yet: CI's key is ${ci}, and ${f} is not encrypted to it."
        echo "         It is encrypted to: $(printf '%s ' $recips)"
        exit 1
      fi
      if [ "$(printf '%s\n' "$recips" | wc -l | tr -d ' ')" -lt 2 ]; then
        echo "not yet: ${f} is encrypted to one key, and CI holds it — so whoever edits the file holds CI's key too."
        echo "         Give CI an identity of its own and encrypt to both: then a leaked runner costs one key, not every key."
        exit 1
      fi
      if [ "$state" != success ]; then
        echo "not yet: run #${run} is ${state:-unfinished}: http://localhost:3000/${repo}/actions/runs/${run}"
        exit 1
      fi
      for row in "DB_PASSWORD:velvet-Orchard-4417-quay:3960cc1656f6" \
                 "PAYMENTS_API_KEY:pgw_live_7c1e0a9f4b3d2e68a5:4b0ef3f898fd" \
                 "SESSION_SECRET:3f9d1c7ab2e04f6d8a51c9e7b0d2f4a6:2a54041f71db"; do
        name=${row%%:*}; fp=${row##*:}
        if ! printf '%s\n' "$logs" | grep -q "${name} fingerprint=${fp}"; then
          echo "not yet: CI decrypted ${name}, and it is not the value in secrets.env."
          exit 1
        fi
      done

      echo "PASS — ciphertext in git, plaintext in no commit, and run #${run} decrypted it as ${ci}."
---
