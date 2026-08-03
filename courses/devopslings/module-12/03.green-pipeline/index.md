---
kind: lesson
title: "The pipeline is green and has never run a test"
description: |
  Every commit for the last month went green. The badge in the README says
  passing. There is a test suite, there is a CI job, and the two have never
  met — and a bug that the suite catches is sitting in main.
name: green-pipeline
slug: green-pipeline
createdAt: "2026-08-02"

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

      git clone -q "$repo" "$work/checkout"
      cd "$work/checkout"
      git config user.email devops@example.invalid
      git config user.name devops

      # Clear the other module-07 lessons out of the way — they share this repo.
      mkdir -p src .forgejo/workflows
      rm -f src/pricing.js src/pricing.test.js src/deploy.js \
        .forgejo/workflows/test.yml .forgejo/workflows/deploy.yml

      # The bug. Every line reads fine; it just never looks at qty, so a cart
      # with three of something charges for one.
      cat > src/cart.js <<'JS'
      function cartTotal(items) {
        return items.reduce((sum, item) => sum + item.price, 0);
      }

      module.exports = { cartTotal };
      JS

      # The suite that catches it. Three tests, one of which is red right now —
      # which nobody has found out, because nothing runs them.
      cat > src/cart.test.js <<'JS'
      const assert = require("node:assert");
      const test = require("node:test");
      const { cartTotal } = require("./cart");

      test("an empty cart is zero", () => {
        assert.strictEqual(cartTotal([]), 0);
      });

      test("one of one item", () => {
        assert.strictEqual(cartTotal([{ price: 9.5, qty: 1 }]), 9.5);
      });

      test("three of the same item", () => {
        assert.strictEqual(cartTotal([{ price: 9.5, qty: 3 }]), 28.5);
      });
      JS

      # The trap, and it is a real one: the script is called "tests", the
      # workflow asks for "test", and --if-present turns the mismatch into a
      # silent success.
      cat > package.json <<'JSON'
      {
        "name": "checkout",
        "version": "1.0.0",
        "scripts": {
          "tests": "node --test"
        }
      }
      JSON

      cat > .forgejo/workflows/ci.yml <<'YAML'
      name: ci

      on: [push]

      jobs:
        test:
          runs-on: docker
          steps:
            - uses: actions/checkout@v4
            - run: npm run test --if-present
      YAML

      cat > README.md <<'MD'
      # checkout

      ![ci](http://localhost:3000/devops/checkout/actions/workflows/ci.yml/badge.svg)

      Tests run on every push.
      MD

      git add -A
      git commit -qm "add the cart total"
      git push -q origin main --force
      sha=$(git rev-parse HEAD)

      rm -rf "$work"

      # Wait for the run, because "it is green" is the premise of the lesson and
      # not something the student should have to take on trust.
      for _ in $(seq 120); do
        tasks=$(curl -fsS -u devops:devopslings "${api}/repos/devops/checkout/actions/tasks?limit=50" 2>/dev/null || true)
        run=$(printf '%s' "$tasks" | tr '{' '\n' | grep "$sha" \
          | sed -n 's/.*"run_number":\([0-9]*\).*/\1/p' | head -1 || true)
        if [ -n "$run" ]; then
          st=$(printf '%s' "$tasks" | tr '{' '\n' | grep "$sha" | sed -n 's/.*"status":"\([a-z]*\)".*/\1/p' | head -1 || true)
          case "$st" in success|failure) break ;; esac
        fi
        sleep 5
      done

      echo "scenario ready — the pipeline is green"
      echo
      echo "  http://localhost:3000/devops/checkout/actions   (devops / devopslings)"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 900
    run: |
      api="http://127.0.0.1:3000/api/v1"

      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT
      git clone -q "http://devops:devopslings@127.0.0.1:3000/devops/checkout.git" "$work/c"
      cd "$work/c"

      # 1. The suite has to still be the suite. Deleting the red test is the
      #    fastest way to a green pipeline and the whole thing this lesson is
      #    about.
      tests=$(grep -c '^test(' src/cart.test.js 2>/dev/null || echo 0)
      if [ "$tests" -lt 3 ]; then
        echo "not yet: src/cart.test.js has ${tests} tests, and the lesson shipped 3."
        echo "         Deleting the test that fails is not the same as passing it."
        exit 1
      fi

      # 2. Nothing may swallow a failure. A job that cannot go red is not a check.
      wf=$(cat .forgejo/workflows/*.yml 2>/dev/null || true)
      if printf '%s' "$wf" | grep -qE 'continue-on-error:[[:space:]]*true|\|\|[[:space:]]*true|\|\|[[:space:]]*exit[[:space:]]+0'; then
        echo "not yet: the workflow still swallows a failure (continue-on-error / || true)."
        echo "         A job that cannot go red is not a check."
        exit 1
      fi

      # 3. The run for this commit has to be green.
      head_sha=$(git rev-parse HEAD)
      state=""
      for _ in $(seq 120); do
        body=$(curl -fsS -u devops:devopslings "${api}/repos/devops/checkout/commits/main/status" 2>/dev/null || true)
        state=$(printf '%s' "$body" | sed -n 's/^{"state":"\([a-z]*\)".*/\1/p')
        case "$state" in success|failure|error) break ;; esac
        sleep 4
      done
      if [ "$state" != "success" ]; then
        echo "not yet: the run for ${head_sha} is '${state:-not started}'."
        echo "         Honest CI goes red first — that red is the bug the suite was written to catch."
        exit 1
      fi

      # 4. And it has to be green for the right reason. The summary line from
      #    node's test runner is the evidence: three tests ran, three passed.
      #    A pipeline that skips the suite is green in exactly the same way.
      tasks=$(curl -fsS -u devops:devopslings "${api}/repos/devops/checkout/actions/tasks?limit=50" 2>/dev/null || true)
      run=$(printf '%s' "$tasks" | tr '{' '\n' | grep "$head_sha" \
        | sed -n 's/.*"run_number":\([0-9]*\).*/\1/p' | head -1 || true)
      if [ -z "$run" ]; then
        echo "not yet: no run found for ${head_sha} — push the fix and let it run"
        exit 1
      fi
      logs=$(curl -fsS -u devops:devopslings \
        "http://127.0.0.1:3000/devops/checkout/actions/runs/${run}/jobs/0/logs" 2>/dev/null || true)

      pass=$(printf '%s' "$logs" | sed -n 's/.*# pass \([0-9]*\).*/\1/p' | tail -1)
      fail=$(printf '%s' "$logs" | sed -n 's/.*# fail \([0-9]*\).*/\1/p' | tail -1)
      if [ -z "$pass" ]; then
        echo "not yet: run #${run} is green, and its log has no test summary in it at all."
        echo "         Nothing ran. That is the same green you started with."
        exit 1
      fi
      if [ "$pass" -lt 3 ] || [ "${fail:-0}" -ne 0 ]; then
        echo "not yet: run #${run} reports ${pass} passing and ${fail:-0} failing — the suite has 3 tests."
        exit 1
      fi

      echo "PASS — ${pass} tests ran in CI, ${fail} failed, and the pipeline can go red again."
---
