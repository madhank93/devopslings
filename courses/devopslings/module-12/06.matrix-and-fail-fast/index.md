---
kind: lesson
title: "the required check is green and one of the shards is red"
description: |
  The test job is a three-way matrix and the branch's required check is a
  summary job that waits for it. It reports success whatever the shards did.
  Learn what `needs` does and does not mean, and how to retry a flaky shard
  without also swallowing a real failure.
name: matrix-and-fail-fast
slug: matrix-and-fail-fast
createdAt: "2026-09-01"

sandbox:
  stack: ci-stack
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 900
    run: |
      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT

      git clone -q "http://devops:devopslings@127.0.0.1:3000/devops/checkout.git" "$work/checkout"
      cd "$work/checkout"
      git config user.email devops@example.invalid
      git config user.name devops

      rm -rf .forgejo .github src vendor node_modules package.json package-lock.json
      mkdir -p src .forgejo/workflows

      cat > src/discount.js <<'JS'
      function applyDiscount(price, percent) {
        if (percent < 0 || percent > 100) {
          throw new RangeError("percent must be between 0 and 100");
        }
        return Math.round((price - (price * percent) / 100) * 100) / 100;
      }

      module.exports = { applyDiscount };
      JS

      cat > src/unit.test.js <<'JS'
      const assert = require("node:assert");
      const test = require("node:test");
      const { applyDiscount } = require("./discount");

      test("applies a percentage discount", () => {
        assert.strictEqual(applyDiscount(100, 10), 90);
      });
      JS

      cat > src/contract.test.js <<'JS'
      const assert = require("node:assert");
      const test = require("node:test");
      const { applyDiscount } = require("./discount");

      test("rejects a nonsense percentage", () => {
        assert.throws(() => applyDiscount(100, 101), RangeError);
      });
      JS

      cat > src/integration.test.js <<'JS'
      const assert = require("node:assert");
      const fs = require("node:fs");
      const test = require("node:test");

      // The integration suite talks to a pricing service that is not always up
      // when the job starts. This stands in for that: the first attempt in a
      // fresh container fails, a later one in the same container succeeds.
      const marker = "/tmp/integration-attempted";

      test("checkout reaches the pricing service", () => {
        if (!fs.existsSync(marker)) {
          fs.writeFileSync(marker, "1");
          assert.fail("ECONNRESET talking to pricing service");
        }
        assert.ok(true);
      });
      JS

      # `gate` exists because branch protection wants one required check rather
      # than one per shard. `if: always()` is there so it still reports when a
      # shard is skipped.
      cat > .forgejo/workflows/ci.yml <<'YAML'
      name: ci

      on: [push]

      jobs:
        test:
          runs-on: docker
          strategy:
            fail-fast: false
            matrix:
              shard: [unit, contract, integration]
          steps:
            - uses: actions/checkout@v4
            - run: node --test src/${{ matrix.shard }}.test.js

        gate:
          runs-on: docker
          needs: [test]
          if: always()
          steps:
            - run: echo "all checks complete"
      YAML

      git add -A
      git commit -qm "three-shard test matrix with a summary gate"
      git push -q origin main --force

      echo "scenario ready"
      echo
      echo "  forge:  http://localhost:3000   (devops / devopslings)"
      echo "  repo:   devops/checkout — 'gate' is the branch's required check"
      echo
      echo "Watch a run, then compare the shard checks with the gate:"
      echo "  http://localhost:3000/devops/checkout/actions"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 900
    run: |
      api="http://127.0.0.1:3000/api/v1"
      auth="-u devops:devopslings"
      repo="devops/checkout"

      # The state of one named check on a commit, newest entry first. Forgejo
      # records every transition, so the first line for a context is its current
      # state. Empty means no such check ran.
      context_status() {
        _sha=$1
        _match=$2
        _i=0
        _seen=0
        while [ "$_i" -lt 100 ]; do
          _body=$(curl -fsS $auth "${api}/repos/${repo}/commits/${_sha}/statuses" 2>/dev/null || true)
          _state=$(printf '%s' "$_body" \
            | tr '}' '\n' \
            | grep "$_match" \
            | sed -n 's/.*"status":"\([a-z]*\)".*/\1/p' \
            | head -1)
          case "$_state" in
            success|failure|error) printf '%s' "$_state"; return 0 ;;
            pending) _seen=1 ;;
          esac
          _i=$((_i + 1))
          if [ "$_seen" = "0" ] && [ "$_i" -ge 20 ]; then break; fi
          sleep 3
        done
        printf '%s' "$_state"
      }

      work=$(mktemp -d)
      head_sha=""
      restore() {
        if [ -n "$head_sha" ] && [ -d "$work/checkout" ]; then
          git -C "$work/checkout" push -q --force \
            "http://devops:devopslings@127.0.0.1:3000/${repo}.git" \
            "${head_sha}:main" >/dev/null 2>&1 || true
        fi
        rm -rf "$work"
      }
      trap restore EXIT

      if ! git clone -q "http://devops:devopslings@127.0.0.1:3000/${repo}.git" "$work/checkout" 2>/dev/null; then
        echo "not yet: could not clone the repository"
        exit 1
      fi
      cd "$work/checkout"
      git config user.email grader@example.invalid
      git config user.name grader
      head_sha=$(git rev-parse HEAD)

      wf=$(cat .forgejo/workflows/*.yml .forgejo/workflows/*.yaml \
             .github/workflows/*.yml .github/workflows/*.yaml 2>/dev/null || true)
      case "$wf" in
        *matrix*) ;;
        *)
          echo "not yet: the workflow no longer runs a matrix. Collapsing three shards"
          echo "into one job does make the report honest, and it gives up the parallelism"
          echo "the shards are for. Keep the matrix."
          exit 1
          ;;
      esac

      gate=$(context_status "$head_sha" 'gate')
      if [ -z "$gate" ]; then
        echo "not yet: no check called 'gate' reported on the tip of main. Branch"
        echo "protection requires that context by name, so a workflow that no longer"
        echo "produces it leaves the branch with nothing to require."
        exit 1
      fi
      if [ "$gate" != "success" ]; then
        echo "not yet: 'gate' reports '$gate' on a commit whose code is fine."
        echo "The integration shard fails on its first attempt in a fresh container and"
        echo "passes on the next one. Making the gate honest without dealing with that"
        echo "turns a flaky suite into a red main."
        exit 1
      fi

      # And the half that the first one is not: a genuine failure in one shard
      # has to reach the gate.
      cat >> src/contract.test.js <<'JS'

      test("grader: a contract the code does not meet", () => {
        assert.strictEqual(applyDiscount(100, 10), 91);
      });
      JS

      git add -A
      git commit -qm "grader: break the contract shard"
      if ! git push -q origin main 2>/dev/null; then
        echo "not yet: could not push the failing commit"
        exit 1
      fi
      probe_sha=$(git rev-parse HEAD)

      probe_gate=$(context_status "$probe_sha" 'gate')
      probe_shard=$(context_status "$probe_sha" 'contract')
      cd /
      restore
      trap - EXIT

      if [ "$probe_shard" != "failure" ]; then
        echo "not yet: a commit with a failing assertion in the contract shard reported"
        echo "'${probe_shard:-nothing}' for that shard. The shard itself has to fail before"
        echo "anything downstream can notice."
        exit 1
      fi

      if [ "$probe_gate" != "failure" ]; then
        echo "not yet: the contract shard failed and 'gate' reported '${probe_gate:-nothing}'."
        echo "'needs:' orders jobs, it does not import their verdict, and 'if: always()'"
        echo "asks the gate to run even when what it needs did not succeed. A summary job"
        echo "that never reads the result of what it waited for is a green light wired to"
        echo "nothing."
        exit 1
      fi

      echo "PASS — 'gate' is green on a healthy commit despite the flaky shard, and red"
      echo "when a shard genuinely fails."
---
