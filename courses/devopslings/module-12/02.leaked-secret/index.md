---
kind: lesson
title: "There's a deploy token committed in the workflow file"
description: |
  Someone hardcoded a deploy token in a workflow to get a release out. It
  works, it's in git history, and it's printed in every build log. Fix it
  properly — which is not just deleting the line, because the line is the least
  of your problems.
name: leaked-secret
slug: leaked-secret
createdAt: "2026-07-31"

sandbox:
  stack: ci-stack
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 600
    run: |
      work=$(mktemp -d)
      repo="http://devops:devopslings@127.0.0.1:3000/devops/checkout.git"
      api="http://127.0.0.1:3000/api/v1"

      # Clear any secret from a previous attempt, so `reset` really resets.
      curl -fsS -u devops:devopslings -X DELETE \
        "${api}/repos/devops/checkout/actions/secrets/DEPLOY_TOKEN" >/dev/null 2>&1 || true

      git clone -q "$repo" "$work/checkout"
      cd "$work/checkout"
      git config user.email devops@example.invalid
      git config user.name devops

      mkdir -p src .forgejo/workflows
      rm -f src/pricing.js src/pricing.test.js .forgejo/workflows/test.yml

      cat > src/deploy.js <<'JS'
      // Pretends to deploy. Prints the token it was given, which is a habit
      // that survives in real codebases for as long as nobody looks — and
      // prints a fingerprint of it, which is what it should have been doing
      // all along. The fingerprint is how the check knows whether the value
      // changed, because a forge masks a known secret in log output and
      // cannot mask a hash of it.
      const crypto = require("crypto");
      const token = process.env.DEPLOY_TOKEN || "";
      if (!token) {
        console.error("FATAL: DEPLOY_TOKEN is not set");
        process.exit(1);
      }
      const fp = crypto.createHash("sha256").update(token).digest("hex").slice(0, 12);
      console.log(`deploying with token=${token}`);
      console.log(`token fingerprint=${fp}`);
      console.log("deployed ok");
      JS

      cat > package.json <<'JSON'
      {
        "name": "checkout",
        "version": "1.0.0",
        "scripts": {
          "deploy": "node src/deploy.js"
        }
      }
      JSON

      # The bad workflow. The token is right there in the YAML: in git, in
      # every clone, and echoed into every build log.
      cat > .forgejo/workflows/deploy.yml <<'YAML'
      name: deploy

      on: [push]

      env:
        DEPLOY_TOKEN: "dpl_9f3c1a7e5b2d4086af11c7e390bb42d1"

      jobs:
        deploy:
          runs-on: docker
          steps:
            - uses: actions/checkout@v4
            - run: npm run deploy
      YAML

      cat > README.md <<'MD'
      # checkout

      `npm run deploy` needs DEPLOY_TOKEN.
      MD

      git add -A
      git commit -qm "add deploy step"
      git push -q origin main --force
      sha=$(git rev-parse HEAD)

      rm -rf "$work"

      # Wait for that push's run to finish. The premise of the lesson is that
      # the token has already been printed into a build log, so the scenario is
      # not ready until it has been. It also makes the contract test face the
      # state a student faces: a completed run whose log holds the literal, for
      # good. A check that only ever saw the fresh-stack case once graded that
      # log and made a correct fix impossible to pass.
      for _ in $(seq 120); do
        tasks=$(curl -fsS -u devops:devopslings "${api}/repos/devops/checkout/actions/tasks?limit=50" 2>/dev/null || true)
        # || true: the run does not exist yet on the first few passes, and a
        # grep that matches nothing would take `set -e` down with it.
        run=$(printf '%s' "$tasks" | tr '{' '\n' | grep "$sha" \
          | sed -n 's/.*"run_number":\([0-9]*\).*/\1/p' | head -1 || true)
        if [ -n "$run" ]; then
          logs=$(curl -fsS -u devops:devopslings \
            "http://127.0.0.1:3000/devops/checkout/actions/runs/${run}/jobs/0/logs" 2>/dev/null || true)
          case "$logs" in *"deployed ok"*) break ;; esac
        fi
        sleep 5
      done

      echo "scenario ready — the token is committed at .forgejo/workflows/deploy.yml"
      echo
      echo "  http://localhost:3000/devops/checkout   (devops / devopslings)"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 900
    run: |
      api="http://127.0.0.1:3000/api/v1"
      leaked="dpl_9f3c1a7e5b2d4086af11c7e390bb42d1"

      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT
      git clone -q "http://devops:devopslings@127.0.0.1:3000/devops/checkout.git" "$work/c"

      # 1. The old value must be gone from the working tree.
      if grep -rq "$leaked" "$work/c" --exclude-dir=.git 2>/dev/null; then
        echo "not yet: the old token is still in the tree on main"
        exit 1
      fi

      # 2. The workflow must still source it from somewhere. A deploy that no
      #    longer authenticates is not a fix.
      wf=$(cat "$work/c/.forgejo/workflows/deploy.yml" 2>/dev/null || true)
      if [ -z "$wf" ]; then
        echo "not yet: .forgejo/workflows/deploy.yml is gone — deleting the pipeline is not fixing the leak"
        exit 1
      fi
      if ! printf '%s' "$wf" | grep -q 'secrets\.'; then
        echo "not yet: the workflow does not reference secrets.* — where is DEPLOY_TOKEN coming from now?"
        exit 1
      fi

      # 3. The secret has to actually exist.
      secrets=$(curl -fsS -u devops:devopslings "${api}/repos/devops/checkout/actions/secrets" 2>/dev/null || true)
      if ! printf '%s' "$secrets" | grep -qi 'DEPLOY_TOKEN'; then
        echo "not yet: no DEPLOY_TOKEN secret is configured on the repo"
        echo "         Settings -> Actions -> Secrets, or POST to the API"
        exit 1
      fi

      # 4. And the deploy has to still work.
      state=""
      for _ in $(seq 100); do
        body=$(curl -fsS -u devops:devopslings "${api}/repos/devops/checkout/commits/main/status" 2>/dev/null || true)
        state=$(printf '%s' "$body" | sed -n 's/^{"state":"\([a-z]*\)".*/\1/p')
        case "$state" in success|failure|error) break ;; esac
        sleep 4
      done
      if [ "$state" != "success" ]; then
        echo "not yet: the deploy run is '${state:-not started}' — moving the secret must not break the pipeline"
        exit 1
      fi

      # 5. The value must be a *different* one. This is the point of the
      #    lesson: the original was published the moment it was pushed, so
      #    moving that same string into a secret store changes nothing about
      #    who knows it.
      #
      #    Only the run for the current HEAD is graded. Earlier runs printed
      #    the literal and always will — a log is a record of a moment, and
      #    classifying the value as secret afterwards does not travel back
      #    through it. Grading those would make a correct fix ungradeable.
      head_sha=$(git -C "$work/c" rev-parse HEAD)
      tasks=$(curl -fsS -u devops:devopslings "${api}/repos/devops/checkout/actions/tasks?limit=50" 2>/dev/null || true)
      run=$(printf '%s' "$tasks" | tr '{' '\n' | grep "$head_sha" \
        | sed -n 's/.*"run_number":\([0-9]*\).*/\1/p' | head -1 || true)
      if [ -z "$run" ]; then
        echo "not yet: no run found for ${head_sha} — push the fix and let it run"
        exit 1
      fi
      logs=$(curl -fsS -u devops:devopslings \
        "http://127.0.0.1:3000/devops/checkout/actions/runs/${run}/jobs/0/logs" 2>/dev/null || true)

      #    The forge masks a value it knows is a secret, so the printed token
      #    is *** either way and says nothing about whether it was rotated.
      #    The fingerprint is a hash, so it survives masking. This one is
      #    sha256("dpl_9f3c…")[:12] — the original.
      leaked_fp=c5bb5b4bc073
      fp=$(printf '%s' "$logs" | sed -n 's/.*token fingerprint=\([0-9a-f]*\).*/\1/p' | head -1)
      if [ -z "$fp" ]; then
        echo "not yet: run #${run} printed no token fingerprint — src/deploy.js must keep"
        echo "         printing it, that line is what the check reads"
        exit 1
      fi
      if [ "$fp" = "$leaked_fp" ] || printf '%s' "$logs" | grep -q "$leaked"; then
        echo "not yet: run #${run} deployed with the original token value."
        echo "         It was moved into a secret, not rotated — and it has been"
        echo "         public since the first push. Issue a new one."
        exit 1
      fi

      echo "PASS — out of the repo, sourced from a secret, rotated to a new value, and the deploy still works."
---
