---
kind: lesson
title: "CI is green and the dependency it tested is not the one in the lockfile"
description: |
  The pipeline caches node_modules so builds are fast. It restores that cache
  whatever the lockfile says, so a dependency upgrade is tested against the
  packages from before it. Learn what belongs in a cache key, and why "clear
  the cache" is a ritual rather than a fix.
name: cache-poisoned-green
slug: cache-poisoned-green
createdAt: "2026-09-01"

sandbox:
  stack: ci-stack
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 900
    run: |
      # A protection rule left by another lesson (any name, any pattern) would
      # refuse the seed force-push, so every rule on the repository goes first.
      for rule in $(curl -fsS -u devops:devopslings \
                      "http://127.0.0.1:3000/api/v1/repos/devops/checkout/branch_protections" 2>/dev/null \
                    | tr ',' '\n' | sed -n 's/.*"rule_name":"\([^"]*\)".*/\1/p' \
                    | sed 's/%/%25/g; s/ /%20/g; s/\*/%2A/g; s/?/%3F/g; s/\[/%5B/g; s/]/%5D/g; s|/|%2F|g' || true); do
        curl -fsS -u devops:devopslings -X DELETE \
          "http://127.0.0.1:3000/api/v1/repos/devops/checkout/branch_protections/${rule}" >/dev/null 2>&1 || true
      done

      api="http://127.0.0.1:3000/api/v1"
      auth="-u devops:devopslings"
      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT

      git clone -q "http://devops:devopslings@127.0.0.1:3000/devops/checkout.git" "$work/checkout"
      cd "$work/checkout"
      git config user.email devops@example.invalid
      git config user.name devops

      rm -rf .forgejo .github src vendor node_modules package-lock.json
      mkdir -p src vendor .forgejo/workflows

      # The shared pricing library, vendored as tarballs. 2.0.0 raises the cap
      # and drops legacyRound; nothing has upgraded to it yet.
      printf '%s' 'H4sIAAAAAAAC/+2VwWoCMRRFZ52vuMyqFjvzUscpVNx1241/kManE3WSIclYi/jvZaotUroptIIwZ3Ph3RDyFoc0Sq/VknNj57zLViH5B4ioLAr8NO8YyQLJaFySlGVJBRKS9HA/QkLJBWhDVD4h+oMliQhfeSVoZ0NErXZPJmjX2ogpxjQRIs8x46iM5TkWziNWDF2xXrs2IrDfGs1DvFZGV/CutfOAF144zzARWjUhE4vW6micxYaXSr/NulM3doC9ADzH1ls8q1hl/ljgFpJogLyLiTgIUbt5u+GMd43zMWCK/flLh+f34jARSc+vaU7+nzJbBWcv7L+U99/9l+OCev8vQedialXN6SPSxhtt7PLOtxsO6bCrtuyDcbZrZUYZHae1Mh+jz18jFYfevp6enp6r4h0idc6yAAwAAA==' \
        | base64 -d > vendor/pricing-rules-1.0.0.tgz
      printf '%s' 'H4sIAAAAAAAC/+3VTWrDMBAFYK99iofXqT3Kj0MTsusJegMhDalSWxKS3CSEQA/RE/YkJW5aaOkyDQT8bQZmBoEWT/JSPcs1V8Zq3pWbmP0DIqqnU/zVPxnP5sgms5qEqGuaIiNB84lARtkVdDHJkBFd4JJEhO96I6oK45JKwvvrG7xrjNojSBNZIz0xlPQjSKvR8Fqq/aPrrMZWRujgvGe9gJJNwyFiy4HzqkJyjUZyCP2qTP0xrNcMY2NiqctcORsTWrl7MFG5ziascE/LPG+d7houeeddSBErHH5sHZd5Nrgsf87/uZab6OyV8y+E+J1/MZvMh/xfwyEHCitbLhYofDDK2PVd6BqOxeg0euEQjbOnaf9OfHZbafrW169R5MchSoPBYHBTPgDMCdgVAAwAAA==' \
        | base64 -d > vendor/pricing-rules-2.0.0.tgz

      cat > src/pricing.js <<'JS'
      const { maxDiscount, legacyRound } = require("pricing-rules");

      function applyDiscount(price, percent) {
        if (percent > maxDiscount) {
          throw new RangeError(`discount above the ${maxDiscount}% cap`);
        }
        return legacyRound(price - (price * percent) / 100);
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

      test("refuses a discount above the cap", () => {
        assert.throws(() => applyDiscount(100, 60), RangeError);
      });
      JS

      cat > package.json <<'JSON'
      {
        "name": "checkout",
        "version": "1.0.0",
        "scripts": { "test": "node --test src/*.test.js" },
        "dependencies": { "pricing-rules": "file:vendor/pricing-rules-1.0.0.tgz" }
      }
      JSON

      cat > package-lock.json <<'JSON'
      {
        "name": "checkout",
        "version": "1.0.0",
        "lockfileVersion": 3,
        "requires": true,
        "packages": {
          "": {
            "name": "checkout",
            "version": "1.0.0",
            "dependencies": {
              "pricing-rules": "file:vendor/pricing-rules-1.0.0.tgz"
            }
          },
          "node_modules/pricing-rules": {
            "version": "1.0.0",
            "resolved": "file:vendor/pricing-rules-1.0.0.tgz",
            "integrity": "sha512-hvPjo0jWmhkfImw8EYixYoZbWpcUg9nQosWwdpmUllSvRO5Cm5dorpuyvmz7K0mwkTVznGBseyJSsosksQK3Cw=="
          }
        }
      }
      JSON

      cat > .gitignore <<'IGN'
      node_modules/
      IGN

      # Added when installs started dominating the build. It has done its job:
      # builds went from ninety seconds to twelve.
      cat > .forgejo/workflows/ci.yml <<'YAML'
      name: ci

      on: [push]

      jobs:
        test:
          runs-on: docker
          steps:
            - uses: actions/checkout@v4

            - uses: actions/cache@v4
              id: deps
              with:
                path: node_modules
                key: node-modules-${{ runner.os }}

            - run: npm ci --offline
              if: steps.deps.outputs.cache-hit != 'true'

            - run: npm test
      YAML

      git add -A
      git commit -qm "checkout on pricing-rules 1.0.0, with a dependency cache"
      git push -q origin main --force

      # Let this run finish: it is what populates the cache the exercise is
      # about, so the scenario is not really set up until it has.
      sha=$(git rev-parse HEAD)
      i=0
      while [ "$i" -lt 100 ]; do
        st=$(curl -fsS $auth "${api}/repos/devops/checkout/commits/${sha}/status" 2>/dev/null \
             | sed -n 's/^{"state":"\([a-z]*\)".*/\1/p')
        case "$st" in success|failure|error) break ;; esac
        i=$((i + 1))
        sleep 3
      done

      echo "scenario ready — the first build has run and the cache is warm (${st:-unknown})"
      echo
      echo "  forge:  http://localhost:3000   (devops / devopslings)"
      echo "  repo:   devops/checkout"
      echo
      echo "  git clone http://devops:devopslings@localhost:3000/devops/checkout.git"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 900
    run: |
      api="http://127.0.0.1:3000/api/v1"
      auth="-u devops:devopslings"
      repo="devops/checkout"

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
      if [ -z "$wf" ]; then
        echo "not yet: no workflow file in the repository"
        exit 1
      fi

      # Deleting the cache step makes the pipeline honest and undoes the reason
      # it exists. The build is meant to stay fast.
      case "$wf" in
        *actions/cache*) ;;
        *)
          echo "not yet: the workflow no longer caches anything. Removing the cache does"
          echo "fix the wrong answer, by giving up the ninety seconds a build used to"
          echo "spend installing. Keep the cache and make its key describe what is in it."
          exit 1
          ;;
      esac

      state=$(settled_status "$head_sha")
      if [ "$state" != "success" ]; then
        echo "not yet: the tip of main reports '${state:-no run}'. This commit's tests"
        echo "pass against the dependency its lockfile names — get the pipeline green"
        echo "on it before worrying about the cache."
        exit 1
      fi

      # A key that misses on every commit is also honest, and useless. A commit
      # that leaves the dependencies alone has to restore them and not install.
      echo "grader: nothing to see here" > GRADER.md
      git add -A
      git commit -qm "grader: a change that touches no dependency"
      if ! git push -q origin main 2>/dev/null; then
        echo "not yet: could not push the grader's commit"
        exit 1
      fi
      same_sha=$(git rev-parse HEAD)
      same_state=$(settled_status "$same_sha")
      run=$(curl -fsS $auth "${api}/repos/${repo}/actions/tasks?limit=50" 2>/dev/null \
              | tr '{' '\n' | grep "$same_sha" \
              | sed -n 's/.*"run_number":\([0-9]*\).*/\1/p' | head -1 || true)
      logs=""
      if [ -n "$run" ]; then
        logs=$(curl -fsS $auth \
          "http://127.0.0.1:3000/${repo}/actions/runs/${run}/jobs/0/logs" 2>/dev/null || true)
      fi
      if [ "$same_state" != "success" ]; then
        echo "not yet: a commit that only adds a markdown file reported '${same_state:-no run}'."
        echo "It changes nothing the build depends on."
        exit 1
      fi
      if [ -z "$logs" ]; then
        echo "not yet: could not read the job log for the grader's commit (run '${run:-none}')"
        exit 1
      fi
      if ! printf '%s' "$logs" | grep -q 'Cache restored from key'; then
        echo "not yet: run #${run}, for a commit that only adds a markdown file, did not"
        echo "restore the dependency cache. What the cache step said:"
        printf '%s\n' "$logs" | grep -E 'Cache (not found|restored)' \
          | sed 's/^[0-9TZ:.-]* /  /' | head -2 || true
        echo "The dependencies did not change, so the key should not have either. A key"
        echo "that is new on every commit is never wrong, and never saves an install."
        exit 1
      fi
      if printf '%s' "$logs" | grep -Eq 'added [0-9]+ packages?'; then
        echo "not yet: run #${run}, for a commit that only adds a markdown file, restored"
        echo "the cache and then installed the dependencies anyway ('added … package' is"
        echo "in the log). The install is the ninety seconds the cache exists to skip."
        exit 1
      fi

      # The whole exercise, as a measurement: change the lockfile and nothing
      # else, to a dependency the code genuinely cannot work with, and see
      # whether the pipeline notices.
      cat > package.json <<'JSON'
      {
        "name": "checkout",
        "version": "1.0.0",
        "scripts": { "test": "node --test src/*.test.js" },
        "dependencies": { "pricing-rules": "file:vendor/pricing-rules-2.0.0.tgz" }
      }
      JSON

      cat > package-lock.json <<'JSON'
      {
        "name": "checkout",
        "version": "1.0.0",
        "lockfileVersion": 3,
        "requires": true,
        "packages": {
          "": {
            "name": "checkout",
            "version": "1.0.0",
            "dependencies": {
              "pricing-rules": "file:vendor/pricing-rules-2.0.0.tgz"
            }
          },
          "node_modules/pricing-rules": {
            "version": "2.0.0",
            "resolved": "file:vendor/pricing-rules-2.0.0.tgz",
            "integrity": "sha512-6+dANMlAkZafwbm4RQt8DpJl+tz6We/jFX+tFxo/rV3gsnpiDlkT8Mu9u3sRMF/lt5/GSDRO0dtnZKe+hr+VYg=="
          }
        }
      }
      JSON

      git add -A
      git commit -qm "grader: upgrade pricing-rules to 2.0.0"
      if ! git push -q origin main 2>/dev/null; then
        echo "not yet: could not push the upgrade commit"
        exit 1
      fi
      probe_sha=$(git rev-parse HEAD)

      probe_state=$(settled_status "$probe_sha")
      cd /
      restore
      trap - EXIT

      if [ -z "$probe_state" ] || [ "$probe_state" = "pending" ]; then
        echo "not yet: the upgrade commit produced no finished run"
        exit 1
      fi

      if [ "$probe_state" = "success" ]; then
        echo "not yet: a commit that upgrades pricing-rules to 2.0.0 — which removes a"
        echo "function this code calls — was reported as 'success'."
        echo "The job restored a node_modules from an earlier build and skipped the"
        echo "install, so the tests ran against 1.0.0 while the lockfile said 2.0.0."
        echo "A cache key has to change when the thing in the cache should change."
        exit 1
      fi

      echo "PASS — main is green on the dependency its lockfile names, and changing"
      echo "that lockfile now misses the cache and reports '$probe_state'."
---
