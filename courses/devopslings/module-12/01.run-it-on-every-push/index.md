---
kind: lesson
title: "the workflow exists, and it has never run"
description: |
  There is a ci.yml in the repo. It has never produced a red build, and it has
  never produced a green one either. Learn what triggers a run, and why a step
  that cannot fail tells you nothing when it passes.
name: run-it-on-every-push
slug: run-it-on-every-push
createdAt: "2026-09-01"

sandbox:
  stack: ci-stack
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 600
    run: |
      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT

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
      MD

      # A previous attempt's workflow is a committed file, not container state,
      # so a reset has to remove it explicitly.
      rm -rf .forgejo .github
      mkdir -p .forgejo/workflows

      # Written during onboarding, merged, and never thought about again. It runs
      # only when somebody presses the button, and its one step cannot fail.
      cat > .forgejo/workflows/ci.yml <<'YAML'
      name: ci

      on:
        workflow_dispatch:

      jobs:
        test:
          # This runner advertises `docker` and `host`. Leave this line alone —
          # the next lesson is about what happens when it is wrong.
          runs-on: docker
          steps:
            - uses: actions/checkout@v4
            - run: npm test || true
      YAML

      git add -A
      git commit -qm "checkout service with a ci workflow nobody has run"
      git push -q origin main --force

      echo "scenario ready"
      echo
      echo "  forge:  http://localhost:3000   (devops / devopslings)"
      echo "  repo:   devops/checkout, with .forgejo/workflows/ci.yml"
      echo
      echo "  git clone http://devops:devopslings@localhost:3000/devops/checkout.git"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 900
    run: |
      api="http://127.0.0.1:3000/api/v1"
      auth="-u devops:devopslings"
      repo="devops/checkout"

      # Waits for a commit to reach a settled status, and prints it. Empty means
      # nothing ever reported one.
      # Two budgets, because the two ways to wait forever mean different things.
      # A commit that never gets a status at all was never picked up by a
      # trigger, and that answer arrives in seconds; a commit sitting at
      # 'pending' has a run that is queued or executing, and deserves the wait.
      settled_status() {
        _sha=$1
        _i=0
        _seen=0
        while [ "$_i" -lt 100 ]; do
          _body=$(curl -fsS $auth "${api}/repos/${repo}/commits/${_sha}/status" 2>/dev/null || true)
          _state=$(printf '%s' "$_body" | sed -n 's/^{"state":"\([a-z]*\)".*/\1/p')
          case "$_state" in
            success|failure|error) printf '%s' "$_state"; return 0 ;;
            pending) _seen=1 ;;
          esac
          _i=$((_i + 1))
          if [ "$_seen" = "0" ] && [ "$_i" -ge 15 ]; then break; fi
          sleep 3
        done
        printf '%s' "$_state"
      }

      head_sha=$(curl -fsS $auth "${api}/repos/${repo}/commits?limit=1" 2>/dev/null \
        | sed -n 's/^\[{"url":"[^"]*","sha":"\([0-9a-f]*\)".*/\1/p')
      if [ -z "$head_sha" ]; then
        echo "not yet: could not read the repository's head commit from the forge"
        exit 1
      fi

      state=$(settled_status "$head_sha")
      if [ -z "$state" ] || [ "$state" = "pending" ]; then
        echo "not yet: the commit at the tip of main has no finished run."
        echo "Either nothing triggered on the push, or a run is still waiting to be"
        echo "claimed. A workflow that only lists 'workflow_dispatch' runs when"
        echo "somebody presses a button and at no other time."
        echo "  http://localhost:3000/devops/checkout/actions"
        exit 1
      fi
      if [ "$state" != "success" ]; then
        echo "not yet: the tip of main reports '$state'. The tests in this repo pass —"
        echo "read the run and see what the pipeline is unhappy about:"
        echo "  http://localhost:3000/devops/checkout/actions"
        exit 1
      fi

      # Green is only worth something if red is reachable. Push a commit that
      # genuinely fails and require the pipeline to say so.
      work=$(mktemp -d)
      restore() {
        if [ -n "${head_sha:-}" ] && [ -d "$work/checkout" ]; then
          git -C "$work/checkout" push -q --force \
            "http://devops:devopslings@127.0.0.1:3000/${repo}.git" \
            "${head_sha}:main" >/dev/null 2>&1 || true
        fi
        rm -rf "$work"
      }
      trap restore EXIT

      if ! git clone -q "http://devops:devopslings@127.0.0.1:3000/${repo}.git" "$work/checkout" 2>/dev/null; then
        echo "not yet: could not clone the repository to test a failing build"
        exit 1
      fi
      cd "$work/checkout"
      git config user.email grader@example.invalid
      git config user.name grader

      cat > src/probe.test.js <<'JS'
      const assert = require("node:assert");
      const test = require("node:test");

      test("a test that fails on purpose", () => {
        assert.strictEqual(1, 2);
      });
      JS

      git add -A
      git commit -qm "grader: a commit whose tests fail"
      if ! git push -q origin main 2>/dev/null; then
        echo "not yet: could not push a test commit to main"
        exit 1
      fi
      probe_sha=$(git rev-parse HEAD)

      probe_state=$(settled_status "$probe_sha")
      cd /
      restore
      trap - EXIT

      if [ -z "$probe_state" ] || [ "$probe_state" = "pending" ]; then
        echo "not yet: a commit with a failing test produced no finished run, while"
        echo "the tip of main had one. Whatever triggers the pipeline is not 'every"
        echo "push'."
        exit 1
      fi

      if [ "$probe_state" = "success" ]; then
        echo "not yet: a commit whose tests fail was reported as '$probe_state'."
        echo "The pipeline ran and told you nothing: a job's status is the exit status"
        echo "of its steps, and a step that can never exit non-zero can never be red."
        echo "Look at what the run step does with the command's failure."
        exit 1
      fi

      echo "PASS — a push triggers the run, the tests pass on main, and a commit that"
      echo "breaks them reports '$probe_state' instead of a green tick."
---
