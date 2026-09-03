---
kind: lesson
title: "a change reached main without review"
description: |
  There is a branch protection rule on main. It requires an approving review,
  and a change still got in without one. Find the way around the rule, close
  it, and make the pipeline a condition of merging rather than a decoration.
name: branch-protection-bypass
slug: branch-protection-bypass
createdAt: "2026-09-02"

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
      repo="devops/checkout"

      # Any rule left from a previous attempt would refuse the seed push, so
      # the branch is unprotected while the scenario is written and the rule is
      # created afterwards.
      curl -fsS $auth -X DELETE "${api}/repos/${repo}/branch_protections/main" >/dev/null 2>&1 || true
      curl -fsS $auth -X DELETE "${api}/repos/${repo}/branch_protections/%2A" >/dev/null 2>&1 || true

      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT

      git clone -q "http://devops:devopslings@127.0.0.1:3000/${repo}.git" "$work/checkout"
      cd "$work/checkout"
      git config user.email devops@example.invalid
      git config user.name devops

      rm -rf .forgejo .github src vendor node_modules package.json package-lock.json Dockerfile
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

      cat > src/discount.test.js <<'JS'
      const assert = require("node:assert");
      const test = require("node:test");
      const { applyDiscount } = require("./discount");

      test("applies a percentage discount", () => {
        assert.strictEqual(applyDiscount(100, 10), 90);
      });

      test("rejects a nonsense percentage", () => {
        assert.throws(() => applyDiscount(100, 101), RangeError);
      });
      JS

      cat > .forgejo/workflows/ci.yml <<'YAML'
      name: ci

      on: [push, pull_request]

      jobs:
        build:
          runs-on: docker
          steps:
            - uses: actions/checkout@v4
            - run: node --test src/discount.test.js
      YAML

      git add -A
      git commit -qm "checkout service and its test suite"
      git push -q origin main --force
      seed_sha=$(git rev-parse HEAD)

      # Wait for the pipeline, so the branch has real check contexts to require
      # by name before the student is asked to require one.
      i=0
      while [ "$i" -lt 60 ]; do
        state=$(curl -fsS $auth "${api}/repos/${repo}/actions/tasks?limit=10" 2>/dev/null \
                  | tr '{' '\n' \
                  | grep "\"head_sha\":\"${seed_sha}\"" \
                  | grep '"name":"build"' \
                  | sed -n 's/.*"status":"\([a-z]*\)".*/\1/p' | head -1 || true)
        case "$state" in success|failure|error) break ;; esac
        i=$((i + 1))
        sleep 5
      done

      # The rule as the team wrote it. It asks for an approving review and
      # blocks on a rejected one, which is the part everybody looked at.
      curl -fsS $auth -X POST "${api}/repos/${repo}/branch_protections" \
        -H 'Content-Type: application/json' \
        -d '{"branch_name":"main",
             "required_approvals":1,
             "block_on_rejected_reviews":true,
             "dismiss_stale_approvals":true,
             "enable_push":true,
             "enable_push_whitelist":true,
             "push_whitelist_usernames":["devops"],
             "enable_status_check":false,
             "apply_to_admins":false}' >/dev/null

      # And the change that did not go through any of it.
      cat >> src/discount.js <<'JS'

      // Applied straight to main during an incident. Never reviewed.
      function applyDiscountUnchecked(price, percent) {
        return price - (price * percent) / 100;
      }

      module.exports.applyDiscountUnchecked = applyDiscountUnchecked;
      JS

      git add -A
      git commit -qm "hotfix: skip the range check, prices were rejecting"
      git push -q origin main

      echo "scenario ready"
      echo
      echo "  forge:  http://localhost:3000   (devops / devopslings)"
      echo "  repo:   devops/checkout — main is protected"
      echo
      echo "The rule is at Settings → Branches. The last commit on main did not"
      echo "come from a pull request:"
      echo
      echo "  http://localhost:3000/devops/checkout/commits/branch/main"
      echo
      echo "Read the rule and ask how that commit got there."

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 900
    run: |
      api="http://127.0.0.1:3000/api/v1"
      auth="-u devops:devopslings"
      repo="devops/checkout"

      rules=$(curl -fsS $auth "${api}/repos/${repo}/branch_protections" 2>/dev/null | tr '{' '\n' | grep 'branch_name' || true)
      if [ -z "$rules" ]; then
        echo "not yet: devops/checkout has no branch protection rules at all. The rule"
        echo "was imperfect, not useless — deleting it removes the review requirement"
        echo "along with the hole."
        exit 1
      fi

      # The strongest statement about a branch is what the server does when you
      # push to it, so that is asked first and directly.
      work=$(mktemp -d)
      landed=""
      base_sha=""
      cleanup() {
        if [ -n "$landed" ] && [ -n "$base_sha" ] && [ -d "$work/checkout" ]; then
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

      cat >> src/discount.js <<'JS'

      // grader: pushed straight to main, with no review and no pipeline.
      JS
      git add -A
      git commit -qm "grader: an unreviewed change, straight to main"

      if git push -q origin main 2>/dev/null; then
        landed=1
        echo "not yet: the grader pushed a commit straight to main and the forge took"
        echo "it. Requiring approvals only governs merging a pull request; it says"
        echo "nothing about pushing to the branch, so the rule has to close that path"
        echo "too — for everyone, including whoever is on the push allowlist."
        exit 1
      fi

      approvals=$(printf '%s\n' "$rules" \
        | sed -n 's/.*"required_approvals":\([0-9]*\).*/\1/p' | sort -rn | head -1 || true)
      if [ -z "$approvals" ] || [ "$approvals" -lt 1 ]; then
        echo "not yet: no rule on this repository requires an approving review"
        echo "(required_approvals is ${approvals:-unset}). Closing the push path without"
        echo "keeping the review requirement just moves every change into a pull request"
        echo "that anyone can merge unread."
        exit 1
      fi

      if ! printf '%s\n' "$rules" | grep -q '"enable_status_check":true'; then
        echo "not yet: no rule requires a status check. Nothing stops a pull request"
        echo "whose pipeline is red from being merged — the build is advisory until the"
        echo "branch says otherwise."
        exit 1
      fi

      # A required context is matched by name. The names the pipeline actually
      # reports are the ones on its commits, and they are not the job names.
      curl -fsS $auth "${api}/repos/${repo}/commits/${base_sha}/statuses" 2>/dev/null \
        | tr '}' '\n' | sed -n 's/.*"context":"\([^"]*\)".*/\1/p' | sort -u > "$work/real" || true
      real=$(cat "$work/real")
      if [ -z "$real" ]; then
        echo "not yet: the tip of main carries no check results, so there is no evidence"
        echo "the pipeline runs at all. A required context that nothing reports blocks"
        echo "every merge forever."
        exit 1
      fi

      printf '%s\n' "$rules" \
        | sed -n 's/.*"status_check_contexts":\[\([^]]*\)\].*/\1/p' \
        | tr ',' '\n' | tr -d '"' | sed '/^$/d' > "$work/patterns" || true
      patterns=$(cat "$work/patterns")
      if [ -z "$patterns" ]; then
        echo "not yet: status checks are enabled but no context is named, so the rule"
        echo "requires nothing in particular. Name the check the pipeline reports."
        exit 1
      fi

      # A context name contains spaces ("ci / build (push)"), so both lists are
      # walked a line at a time. Inside `case` the pattern is not field-split,
      # which is what lets a glob with spaces in it still match.
      matched=""
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        while IFS= read -r c; do
          [ -n "$c" ] || continue
          case "$c" in
            $p) matched=1 ;;
          esac
        done < "$work/real"
      done < "$work/patterns"

      if [ -z "$matched" ]; then
        echo "not yet: none of the required contexts match a check this repository"
        echo "actually reports. Required:"
        printf '  %s\n' "$patterns"
        echo "Reported on the tip of main:"
        printf '  %s\n' "$real"
        echo "A required context is matched by name, and the name is not the job's —"
        echo "it is the workflow, the job and the event together. A context nothing"
        echo "reports is not a stricter rule, it is a branch that can never merge."
        exit 1
      fi

      echo "PASS — main refuses a direct push, still requires a review, and requires a"
      echo "check the pipeline actually reports."
---
