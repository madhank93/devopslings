---
kind: lesson
title: "Your first pipeline, and why the runner disagrees with you"
description: |
  A repo with a test suite and no automation. Write a workflow that runs the
  tests on every push — then find out that a workflow which looks correct can
  sit in `waiting` forever because nothing on the runner matches what you
  asked for.
name: first-pipeline
slug: first-pipeline
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

      # The forge is reachable from the host on :3000, and bootstrap.sh already
      # created this user and repo.
      repo_url="http://devops:devopslings@127.0.0.1:3000/devops/checkout.git"

      git clone -q "$repo_url" "$work/checkout"
      cd "$work/checkout"
      git config user.email devops@example.invalid
      git config user.name devops

      mkdir -p src

      cat > src/pricing.js <<'JS'
      // Applies a percentage discount. This code is correct and its tests pass
      // — the exercise is the pipeline, not the program.
      function applyDiscount(price, percent) {
        if (percent < 0 || percent > 100) {
          throw new RangeError("percent must be between 0 and 100");
        }
        return price - (price * percent) / 100;
      }

      module.exports = { applyDiscount };
      JS

      cat > src/pricing.test.js <<'JS'
      const assert = require("node:assert");
      const test = require("node:test");
      const { applyDiscount } = require("./pricing");

      test("applies a percentage discount", () => {
        assert.strictEqual(applyDiscount(100, 10), 90);
      });

      test("a zero discount changes nothing", () => {
        assert.strictEqual(applyDiscount(49.99, 0), 49.99);
      });

      test("rejects a nonsense percentage", () => {
        assert.throws(() => applyDiscount(100, 101), RangeError);
      });
      JS

      cat > package.json <<'JSON'
      {
        "name": "checkout",
        "version": "1.0.0",
        "scripts": {
          "test": "node --test src/*.test.js"
        }
      }
      JSON

      cat > README.md <<'MD'
      # checkout

      Run the tests with `npm test`.

      There is no CI yet. That is the exercise.
      MD

      # Remove any workflow left from a previous attempt, so a reset really
      # resets. Files in a git repo are not container state and survive a
      # `compose down -v`.
      rm -rf .forgejo .github

      git add -A
      git commit -qm "checkout service with tests, no CI yet"
      git push -q origin main --force

      rm -rf "$work"

      echo "scenario ready"
      echo
      echo "  forge:  http://localhost:3000   (devops / devopslings)"
      echo "  repo:   devops/checkout"
      echo
      echo "Clone it and add a workflow:"
      echo "  git clone http://devops:devopslings@localhost:3000/devops/checkout.git"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 900
    run: |
      api="http://127.0.0.1:3000/api/v1"
      auth="-u devops:devopslings"

      # The workflow has to be committed, not merely written locally.
      wf=$(curl -fsS $auth "${api}/repos/devops/checkout/contents/.forgejo/workflows" 2>/dev/null \
           || curl -fsS $auth "${api}/repos/devops/checkout/contents/.github/workflows" 2>/dev/null \
           || true)
      if [ -z "$wf" ] || [ "$wf" = "[]" ]; then
        echo "not yet: no workflow file pushed — put one in .forgejo/workflows/ (or .github/workflows/) and push it"
        exit 1
      fi

      # Workflow runs report their outcome as a commit status, which is the
      # stable way to ask "did CI pass for this commit". (The actions/tasks API
      # lists a *runner's* tasks, not workflow runs, and is empty here.)
      status_url="${api}/repos/devops/checkout/commits/main/status"

      state=""
      desc=""
      for _ in $(seq 100); do
        body=$(curl -fsS $auth "$status_url" 2>/dev/null || true)
        state=$(printf '%s' "$body" | sed -n 's/^{"state":"\([a-z]*\)".*/\1/p')
        desc=$(printf '%s' "$body" | sed -n 's/.*"description":"\([^"]*\)".*/\1/p' | head -1)
        case "$state" in
          success|failure|error) break ;;
        esac
        sleep 4
      done

      if [ -z "$state" ] || [ "$state" = "" ]; then
        echo "not yet: the push did not trigger a run — check the 'on:' trigger in your workflow"
        exit 1
      fi

      if [ "$state" = "pending" ]; then
        # The commonest first-workflow failure, and it looks like nothing is
        # happening rather than like an error.
        echo "not yet: the run is still '${desc:-pending}' after 400s — no runner has claimed it."
        echo
        echo "         This runner advertises exactly two labels: 'docker' and 'host'."
        echo "         A job asking for anything else waits forever, because"
        echo "         'ubuntu-latest' is a GitHub-hosted label and there are no"
        echo "         GitHub-hosted runners here."
        echo
        echo "         Check the labels:  http://localhost:3000/admin/actions/runners"
        exit 1
      fi

      if [ "$state" != "success" ]; then
        echo "not yet: the run finished as '$state' (${desc:-no description})"
        echo "         Read the log: http://localhost:3000/devops/checkout/actions"
        exit 1
      fi

      echo "PASS — a push triggered a run, a runner claimed it, and the tests passed."
---
