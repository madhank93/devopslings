---
kind: lesson
title: "production is running a commit that is not on main"
description: |
  Two branches deploy to the same environment, and the slower deploy finishes
  last. Production ends up on an emergency branch nobody merged. Learn why the
  fix is one road to production rather than a faster one.
name: deploy-race
slug: deploy-race
createdAt: "2026-09-03"

sandbox:
  stack: ci-stack
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 900
    run: |
      api="http://127.0.0.1:3000/api/v1"
      auth="-u devops:devopslings"
      reg="http://127.0.0.1:5000"
      repo="devops/checkout"
      accept='application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'

      # A branch protection rule left by an earlier lesson refuses the seed
      # force-push, and a stale :live tag would show the wrong environment.
      curl -fsS $auth -X DELETE "${api}/repos/${repo}/branch_protections/main" >/dev/null 2>&1 || true
      tags=$(curl -fsS "${reg}/v2/checkout/tags/list" 2>/dev/null \
               | tr ',[]' '\n\n\n' | sed -n 's/.*"\([^"]*\)".*/\1/p' \
               | grep -v '^tags$\|^name$\|^checkout$' || true)
      for tag in $tags; do
        digest=$(curl -fsS -H "Accept: ${accept}" -o /dev/null -D - \
                   "${reg}/v2/checkout/manifests/${tag}" 2>/dev/null \
                   | grep -i '^docker-content-digest:' | tr -d '\r' | awk '{print $2}' || true)
        if [ -n "$digest" ]; then
          curl -fsS -X DELETE "${reg}/v2/checkout/manifests/${digest}" >/dev/null 2>&1 || true
        fi
      done
      curl -fsS $auth -X DELETE "${api}/repos/${repo}/branches/hotfix%2Fpricing" >/dev/null 2>&1 || true

      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT

      git clone -q "http://devops:devopslings@127.0.0.1:3000/${repo}.git" "$work/checkout"
      cd "$work/checkout"
      git config user.email devops@example.invalid
      git config user.name devops

      rm -rf .forgejo .github src vendor node_modules package.json package-lock.json Dockerfile migrations
      mkdir -p src .forgejo/workflows

      cat > src/server.js <<'JS'
      const http = require("node:http");

      const RATE = 0.2;

      http
        .createServer((req, res) => {
          res.setHeader("content-type", "application/json");
          res.end(JSON.stringify({ rate: RATE }));
        })
        .listen(8080);
      JS

      cat > Dockerfile <<'DOCKER'
      FROM node:22-bookworm-slim
      ARG GIT_SHA
      LABEL git.sha="${GIT_SHA}"
      WORKDIR /app
      COPY src/ ./src/
      CMD ["node", "src/server.js"]
      DOCKER

      # The emergency path, added during an incident and kept: a hotfix branch
      # deploys to production without waiting for a merge. It is the same job
      # as main's, so it writes the same tag.
      cat > .forgejo/workflows/deploy.yml <<'YAML'
      name: deploy

      on:
        push:
          branches: [main, 'hotfix/**']

      env:
        IMAGE: 127.0.0.1:5000/checkout

      jobs:
        deploy:
          runs-on: docker
          container:
            image: docker:27-cli
            options: -v /var/run/docker.sock:/var/run/docker.sock
          steps:
            - run: |
                git clone -q http://forge:3000/devops/checkout.git .
                git checkout -q "${{ github.sha }}"

                # Pending schema changes are applied before the new code is live.
                if [ -d migrations ]; then
                  echo "applying migrations"
                  sleep 15
                fi

                docker build --build-arg GIT_SHA="${{ github.sha }}" -t "${IMAGE}:live" .
                docker push "${IMAGE}:live"
                echo "live is now ${{ github.sha }}"
      YAML

      git add -A
      git commit -qm "pricing service, deployed from main and from hotfix branches"
      git push -q origin main --force
      main_sha=$(git rev-parse HEAD)

      wait_deploy() {
        _sha=$1
        _i=0
        while [ "$_i" -lt 60 ]; do
          _s=$(curl -fsS $auth "${api}/repos/${repo}/actions/tasks?limit=10" 2>/dev/null \
                 | tr '{' '\n' \
                 | grep "\"head_sha\":\"${_sha}\"" \
                 | grep '"name":"deploy"' \
                 | sed -n 's/.*"status":"\([a-z]*\)".*/\1/p' | head -1 || true)
          case "$_s" in success|failure|error|cancelled) return 0 ;; esac
          _i=$((_i + 1))
          sleep 5
        done
        return 0
      }
      wait_deploy "$main_sha"

      # The incident: a hotfix goes straight out from its own branch. It carries
      # a schema change, so its deploy is the slow one — and it finishes after
      # main's, leaving production on a commit that was never merged.
      git checkout -q -b hotfix/pricing
      mkdir -p migrations
      cat > migrations/003_rate_precision.sql <<'SQL'
      ALTER TABLE prices ALTER COLUMN rate TYPE numeric(6, 4);
      SQL
      sed -i.bak 's/const RATE = 0.2;/const RATE = 0.185;/' src/server.js
      rm -f src/server.js.bak
      git add -A
      git commit -qm "hotfix: correct the pricing rate"
      git push -q origin hotfix/pricing
      hotfix_sha=$(git rev-parse HEAD)
      wait_deploy "$hotfix_sha"

      echo "scenario ready"
      echo
      echo "  forge:     http://localhost:3000   (devops / devopslings)"
      echo "  registry:  http://localhost:5000"
      echo
      echo "main is at    ${main_sha}"
      echo "hotfix is at  ${hotfix_sha}"
      echo
      echo "Ask production which commit it is running:"
      echo
      echo '  curl -s http://127.0.0.1:5000/v2/checkout/manifests/live \'
      echo '    -H "Accept: application/vnd.docker.distribution.manifest.v2+json"'
      echo
      echo "then read git.sha out of its config blob, and look for that commit on main."

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 900
    run: |
      api="http://127.0.0.1:3000/api/v1"
      auth="-u devops:devopslings"
      reg="http://127.0.0.1:5000"
      repo="devops/checkout"
      accept='application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'
      probe_branch="hotfix/grader-probe"

      # Which commit production is running, read off the deployed image. Every
      # lookup may legitimately find nothing, so each absorbs its own failure
      # rather than killing the script under `set -euo pipefail`.
      live_sha() {
        _cfg=$(curl -fsS -H "Accept: ${accept}" "${reg}/v2/checkout/manifests/live" 2>/dev/null \
                 | tr -d ' \n' | sed -n 's/.*"config":{[^}]*"digest":"\(sha256:[0-9a-f]*\)".*/\1/p' || true)
        [ -n "$_cfg" ] || return 0
        curl -fsS "${reg}/v2/checkout/blobs/${_cfg}" 2>/dev/null \
          | tr ',' '\n' | sed -n 's/.*"git.sha":"\([0-9a-f]*\)".*/\1/p' | head -1 || true
      }

      # Second argument is the poll budget. The probe branch is expected to
      # produce no run at all once the lesson is solved, so waiting the full
      # budget for it would add five idle minutes to every check.
      wait_deploy() {
        _sha=$1
        _max=${2:-60}
        _i=0
        while [ "$_i" -lt "$_max" ]; do
          _s=$(curl -fsS $auth "${api}/repos/${repo}/actions/tasks?limit=10" 2>/dev/null \
                 | tr '{' '\n' \
                 | grep "\"head_sha\":\"${_sha}\"" \
                 | grep '"name":"deploy"' \
                 | sed -n 's/.*"status":"\([a-z]*\)".*/\1/p' | head -1 || true)
          case "$_s" in success|failure|error|cancelled) printf '%s' "$_s"; return 0 ;; esac
          _i=$((_i + 1))
          sleep 5
        done
        printf '%s' "${_s:-}"
      }

      work=$(mktemp -d)
      base_sha=""
      cleanup() {
        curl -fsS $auth -X DELETE \
          "${api}/repos/${repo}/branches/hotfix%2Fgrader-probe" >/dev/null 2>&1 || true
        if [ -n "$base_sha" ] && [ -d "$work/checkout" ]; then
          git -C "$work/checkout" push -q --force \
            "http://devops:devopslings@127.0.0.1:3000/${repo}.git" \
            "${base_sha}:main" >/dev/null 2>&1 || true
        fi
        rm -rf "$work"
      }
      trap cleanup EXIT

      if ! git clone -q "http://devops:devopslings@127.0.0.1:3000/${repo}.git" "$work/checkout" 2>/dev/null; then
        echo "not yet: could not clone the repository"
        exit 1
      fi
      cd "$work/checkout"
      git config user.email grader@example.invalid
      git config user.name grader
      base_sha=$(git rev-parse HEAD)

      # A merge to main has to reach production, or the pipeline has been fixed
      # by switching it off.
      sed -i.bak 's/const RATE = [0-9.]*;/const RATE = 0.21;/' src/server.js
      rm -f src/server.js.bak
      git add -A
      git commit -qm "grader: a change merged to main"
      if ! git push -q origin main 2>/dev/null; then
        echo "not yet: could not push to main"
        exit 1
      fi
      main_sha=$(git rev-parse HEAD)

      state=$(wait_deploy "$main_sha")
      if [ "$state" != "success" ]; then
        echo "not yet: pushing to main reported '${state:-no deploy at all}'. Production"
        echo "still has to be deployed to from main — a pipeline that no longer ships is"
        echo "not a fixed race."
        exit 1
      fi

      after_main=$(live_sha)
      if [ "$after_main" != "$main_sha" ]; then
        echo "not yet: main is at ${main_sha} and production is running"
        echo "'${after_main:-nothing}'. A merge to main has to end up live."
        exit 1
      fi

      # And the branch that is not main must not be able to replace it.
      git checkout -q -b "$probe_branch"
      mkdir -p migrations
      printf 'ALTER TABLE prices ADD COLUMN grader_probe boolean;\n' > migrations/900_grader.sql
      sed -i.bak 's/const RATE = [0-9.]*;/const RATE = 0.99;/' src/server.js
      rm -f src/server.js.bak
      git add -A
      git commit -qm "grader: an unmerged hotfix, straight from its own branch"
      if ! git push -q origin "$probe_branch" 2>/dev/null; then
        echo "not yet: could not push the probe branch"
        exit 1
      fi
      probe_sha=$(git rev-parse HEAD)

      # Either no deploy runs for this ref, or one runs and declines to publish.
      # Both are acceptable answers, so a run that never appears is not an error
      # here — it is the fix — and the wait is bounded accordingly.
      wait_deploy "$probe_sha" 12 >/dev/null
      sleep 10
      after_probe=$(live_sha)

      cd /
      cleanup
      trap - EXIT

      if [ "$after_probe" = "$probe_sha" ]; then
        echo "not yet: a push to '${probe_branch}' put itself into production."
        echo "Production is now running ${probe_sha}, which is on no branch anyone"
        echo "merged. Two refs that deploy to one environment are two ways to be live,"
        echo "and the one that finishes last wins regardless of which was intended."
        exit 1
      fi

      if [ "$after_probe" != "$main_sha" ]; then
        echo "not yet: after the probe branch was pushed, production is running"
        echo "'${after_probe:-nothing}' rather than main's ${main_sha}. Whatever the"
        echo "hotfix path does now, it must leave what main deployed in place."
        exit 1
      fi

      echo "PASS — a merge to main reaches production, and a push to a hotfix branch"
      echo "cannot replace it."
---
