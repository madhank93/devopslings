---
kind: lesson
title: "CI said the release passed, and staging is broken"
description: |
  Release 1.4 went green through the pipeline and staging fails its smoke test.
  That is the whole ticket, every time, because the fault is drawn at random
  from five, each a different way a pipeline approves something it never
  checked: tests that never ran, a gate that never read its shards, a cache
  keyed on nothing, a branch that wrote staging last, a promote of a stale tag.
  The drill is the order you ask the pipeline questions in.
name: pipeline-triage-drill
slug: pipeline-triage-drill
createdAt: "2026-10-07"

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
      remote="http://devops:devopslings@127.0.0.1:3000/${repo}.git"
      reg="http://127.0.0.1:5000"
      accept='application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'
      drill="$(cd ../.. && pwd)/scratch/pipeline-triage-drill"

      # ---- clean slate -----------------------------------------------------------
      # ci-stack persists between lessons. Protection rules (branch-protection-bypass
      # leaves one that refuses force-pushes), extra branches (deploy-race's hotfix),
      # runs still in flight and registry tags from any earlier lesson all go first.
      for rule in $(curl -fsS $auth "${api}/repos/${repo}/branch_protections" 2>/dev/null \
                      | tr ',' '\n' | sed -n 's/.*"rule_name":"\([^"]*\)".*/\1/p' \
                      | sed 's/%/%25/g; s/ /%20/g; s/\*/%2A/g; s/?/%3F/g; s/\[/%5B/g; s/]/%5D/g; s|/|%2F|g' || true); do
        curl -fsS $auth -X DELETE "${api}/repos/${repo}/branch_protections/${rule}" >/dev/null 2>&1 || true
      done

      for b in $(curl -fsS $auth "${api}/repos/${repo}/branches?limit=50" 2>/dev/null \
                   | tr ',' '\n' | sed -n 's/^\[*{"name":"\([^"]*\)".*/\1/p' | grep -vx main || true); do
        curl -fsS $auth -X DELETE "${api}/repos/${repo}/branches/$(printf '%s' "$b" | sed 's|/|%2F|g')" >/dev/null 2>&1 || true
      done

      # A run from before the reset could still finish afterwards and overwrite the
      # staging tag this scenario is about to set.
      for _ in $(seq 60); do
        busy=$(curl -fsS $auth "${api}/repos/${repo}/actions/tasks?limit=50" 2>/dev/null \
                 | tr '{' '\n' | grep -cE '"status":"(running|waiting|blocked)"' || true)
        [ "${busy:-0}" = "0" ] && break
        sleep 5
      done

      tags=$(curl -fsS "${reg}/v2/checkout/tags/list" 2>/dev/null \
               | tr ',[]' '\n\n\n' | sed -n 's/.*"\([^"]*\)".*/\1/p' \
               | grep -v '^tags$\|^name$\|^checkout$' || true)
      for tag in $tags; do
        digest=$(curl -fsS -H "Accept: ${accept}" -o /dev/null -D - "${reg}/v2/checkout/manifests/${tag}" 2>/dev/null \
                   | grep -i '^docker-content-digest:' | tr -d '\r' | awk '{print $2}' || true)
        [ -n "$digest" ] && curl -fsS -X DELETE "${reg}/v2/checkout/manifests/${digest}" >/dev/null 2>&1 || true
      done

      rm -rf "$drill"
      mkdir -p "$drill/answers"

      # ---- draw the fault ---------------------------------------------------------
      faults="tests gate cache race stale"
      n=$(od -An -N2 -tu2 < /dev/urandom | tr -d ' ')
      fault=$(echo "$faults" | cut -d' ' -f$(( n % 5 + 1 )))

      # ---- helpers ----------------------------------------------------------------
      # Final state of one job of one commit's run; empty while it has not settled.
      job_state() {
        curl -fsS $auth "${api}/repos/${repo}/actions/tasks?limit=50" 2>/dev/null \
          | tr '{' '\n' | grep "\"head_sha\":\"$1\"" | grep "\"name\":\"$2\"" \
          | sed -n 's/.*"status":"\([a-z]*\)".*/\1/p' | head -1 || true
      }
      wait_deploy() {
        _s=""
        for _ in $(seq 72); do
          _s=$(job_state "$1" deploy-staging)
          case "$_s" in success|failure|cancelled|skipped) break ;; esac
          sleep 5
        done
        if [ "$_s" != success ]; then
          echo "the scenario did not come up: deploy-staging for $1 is '${_s:-not started}'" >&2
          exit 1
        fi
      }

      lockfile() {
        cat > package-lock.json <<JSON
      {
        "name": "checkout",
        "version": "$1",
        "lockfileVersion": 3,
        "requires": true,
        "packages": {
          "": {
            "name": "checkout",
            "version": "$1",
            "dependencies": {
              "pricing-rules": "file:vendor/pricing-rules-$2.tgz"
            }
          },
          "node_modules/pricing-rules": {
            "version": "$2",
            "resolved": "file:vendor/pricing-rules-$2.tgz",
            "integrity": "$3"
          }
        }
      }
      JSON
      }
      pkg() {
        cat > package.json <<JSON
      {
        "name": "checkout",
        "version": "$1",
        "scripts": { "$2": "node --test" },
        "dependencies": { "pricing-rules": "file:vendor/pricing-rules-$3.tgz" }
      }
      JSON
      }
      v1_sri="sha512-hvPjo0jWmhkfImw8EYixYoZbWpcUg9nQosWwdpmUllSvRO5Cm5dorpuyvmz7K0mwkTVznGBseyJSsosksQK3Cw=="
      v2_sri="sha512-6+dANMlAkZafwbm4RQt8DpJl+tz6We/jFX+tFxo/rV3gsnpiDlkT8Mu9u3sRMF/lt5/GSDRO0dtnZKe+hr+VYg=="

      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT
      git clone -q "$remote" "$work/checkout"
      cd "$work/checkout"
      git config user.email devops@example.invalid
      git config user.name devops
      find . -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
      mkdir -p src vendor .forgejo/workflows

      # ---- release 1.3 ------------------------------------------------------------
      # pricing-rules 2.0.0 raises the discount cap to 90% and drops legacyRound.
      printf '%s' 'H4sIAAAAAAAC/+2VwWoCMRRFZ52vuMyqFjvzUscpVNx1241/kManE3WSIclYi/jvZaotUroptIIwZ3Ph3RDyFoc0Sq/VknNj57zLViH5B4ioLAr8NO8YyQLJaFySlGVJBRKS9HA/QkLJBWhDVD4h+oMliQhfeSVoZ0NErXZPJmjX2ogpxjQRIs8x46iM5TkWziNWDF2xXrs2IrDfGs1DvFZGV/CutfOAF144zzARWjUhE4vW6micxYaXSr/NulM3doC9ADzH1ls8q1hl/ljgFpJogLyLiTgIUbt5u+GMd43zMWCK/flLh+f34jARSc+vaU7+nzJbBWcv7L+U99/9l+OCev8vQedialXN6SPSxhtt7PLOtxsO6bCrtuyDcbZrZUYZHae1Mh+jz18jFYfevp6enp6r4h0idc6yAAwAAA==' \
        | base64 -d > vendor/pricing-rules-1.0.0.tgz
      printf '%s' 'H4sIAAAAAAAC/+3VTWrDMBAFYK99iofXqT3Kj0MTsusJegMhDalSWxKS3CSEQA/RE/YkJW5aaOkyDQT8bQZmBoEWT/JSPcs1V8Zq3pWbmP0DIqqnU/zVPxnP5sgms5qEqGuaIiNB84lARtkVdDHJkBFd4JJEhO96I6oK45JKwvvrG7xrjNojSBNZIz0xlPQjSKvR8Fqq/aPrrMZWRujgvGe9gJJNwyFiy4HzqkJyjUZyCP2qTP0xrNcMY2NiqctcORsTWrl7MFG5ziascE/LPG+d7houeeddSBErHH5sHZd5Nrgsf87/uZab6OyV8y+E+J1/MZvMh/xfwyEHCitbLhYofDDK2PVd6BqOxeg0euEQjbOnaf9OfHZbafrW169R5MchSoPBYHBTPgDMCdgVAAwAAA==' \
        | base64 -d > vendor/pricing-rules-2.0.0.tgz

      pkg 1.3.0 test 1.0.0
      lockfile 1.3.0 1.0.0 "$v1_sri"
      printf 'node_modules/\n' > .gitignore

      cat > src/cart.js <<'JS'
      const { maxDiscount, legacyRound } = require("pricing-rules");

      // The total for a cart, after a percentage discount capped by pricing policy.
      function cartTotal(items, percent = 0) {
        if (percent < 0 || percent > maxDiscount) {
          throw new RangeError(`discount must be between 0 and ${maxDiscount}%`);
        }
        const gross = items.reduce((sum, item) => sum + item.price, 0);
        return legacyRound(gross - (gross * percent) / 100);
      }

      module.exports = { cartTotal };
      JS

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
      JS

      cat > src/discount.test.js <<'JS'
      const assert = require("node:assert");
      const test = require("node:test");
      const { cartTotal } = require("./cart");

      test("applies a percentage discount", () => {
        assert.strictEqual(cartTotal([{ price: 100, qty: 1 }], 10), 90);
      });

      test("refuses a discount above the cap", () => {
        assert.throws(() => cartTotal([{ price: 100, qty: 1 }], 60), RangeError);
      });

      // Runs in the nightly job, which has credentials for the staging pricing
      // service. Skipped everywhere else by design.
      test("live pricing service agrees with the cart", { skip: "nightly only: needs the staging pricing service" }, async () => {
        const res = await fetch("http://pricing.staging.invalid/v1/quote?sku=EUR-FWD-30");
        assert.strictEqual(res.status, 200);
      });
      JS

      cat > Dockerfile <<'DOCKER'
      FROM node:22-bookworm-slim
      ARG GIT_SHA
      LABEL git.sha="${GIT_SHA}"
      WORKDIR /app
      COPY package.json package-lock.json ./
      COPY vendor/ ./vendor/
      RUN npm ci --offline --omit=dev
      COPY src/ ./src/
      DOCKER

      cat > README.md <<'MD'
      # checkout

      Every push to main is tested, built into `127.0.0.1:5000/checkout`, and
      deployed to staging, which is the `staging` tag in that registry.
      MD

      cat > .forgejo/workflows/release.yml <<'YAML'
      name: release

      on:
        push:
          branches: [main, 'hotfix/**']

      env:
        IMAGE: 127.0.0.1:5000/checkout

      jobs:
        test:
          runs-on: docker
          steps:
            - uses: actions/checkout@v4
            - uses: actions/cache@v4
              id: deps
              with:
                path: node_modules
                key: deps-${{ runner.os }}
            - run: npm ci --offline
              if: steps.deps.outputs.cache-hit != 'true'
            - run: npm test

        build:
          runs-on: docker
          needs: [test]
          container:
            image: docker:27-cli
            options: -v /var/run/docker.sock:/var/run/docker.sock
          steps:
            - run: |
                git clone -q http://forge:3000/devops/checkout.git .
                git checkout -q "${{ github.sha }}"
                docker build -q --build-arg GIT_SHA="${{ github.sha }}" -t "${IMAGE}:latest" .
                docker push -q "${IMAGE}:latest"

        deploy-staging:
          runs-on: docker
          needs: [build]
          container:
            image: docker:27-cli
            options: -v /var/run/docker.sock:/var/run/docker.sock
          steps:
            - run: |
                docker pull -q "${IMAGE}:latest"
                docker tag "${IMAGE}:latest" "${IMAGE}:staging"
                docker push -q "${IMAGE}:staging"
      YAML

      git add -A
      git commit -qm "release 1.3"
      git push -q --force origin HEAD:main
      r13=$(git rev-parse HEAD)
      wait_deploy "$r13"

      # ---- release 1.4 ------------------------------------------------------------
      # Every variant ships the same release: the quantity fix and its test, and a
      # pipeline that builds once per commit and gates on the test matrix. The fault
      # is one line of it.
      script=test
      deps=1.0.0
      qty="item.price * item.qty"
      key="deps-\${{ runner.os }}-\${{ hashFiles('package-lock.json') }}"
      gate='test "${{ needs.test.result }}" = success'
      promote='${{ github.sha }}'
      case "$fault" in
        tests) script=tests; qty="item.price * (item.quantity ?? 1)" ;;
        gate)  gate='echo "all shards complete"'; qty="item.price * (item.quantity ?? 1)" ;;
        cache) deps=2.0.0; key="deps-\${{ runner.os }}" ;;
        stale) promote=latest ;;
      esac

      pkg 1.4.0 "$script" "$deps"
      if [ "$deps" = 2.0.0 ]; then lockfile 1.4.0 2.0.0 "$v2_sri"; else lockfile 1.4.0 1.0.0 "$v1_sri"; fi
      sed -i.bak "s/sum + item.price, 0/sum + ${qty}, 0/" src/cart.js && rm -f src/cart.js.bak

      cat >> src/cart.test.js <<'JS'

      test("three of the same item", () => {
        assert.strictEqual(cartTotal([{ price: 9.5, qty: 3 }]), 28.5);
      });
      JS

      cat > .forgejo/workflows/release.yml <<'YAML'
      name: release

      on:
        push:
          branches: [main, 'hotfix/**']

      env:
        IMAGE: 127.0.0.1:5000/checkout

      jobs:
        test:
          runs-on: docker
          strategy:
            fail-fast: false
            matrix:
              shard: [cart, discount]
          steps:
            - uses: actions/checkout@v4
            - uses: actions/cache@v4
              id: deps
              with:
                path: node_modules
                key: @KEY@
            - run: npm ci --offline
              if: steps.deps.outputs.cache-hit != 'true'
            - run: npm run test --if-present -- src/${{ matrix.shard }}.test.js

        # The one check the release waits on, so a new shard never needs a new rule.
        gate:
          runs-on: docker
          needs: [test]
          if: always()
          steps:
            - run: @GATE@

        # Built once per commit and tagged with it; staging is promoted from this tag.
        build:
          runs-on: docker
          needs: [gate]
          container:
            image: docker:27-cli
            options: -v /var/run/docker.sock:/var/run/docker.sock
          steps:
            - run: |
                git clone -q http://forge:3000/devops/checkout.git .
                git checkout -q "${{ github.sha }}"
                docker build -q --build-arg GIT_SHA="${{ github.sha }}" -t "${IMAGE}:${{ github.sha }}" .
                docker run --rm "${IMAGE}:${{ github.sha }}" node -e 'require("./src/cart")'
                docker push -q "${IMAGE}:${{ github.sha }}"

        deploy-staging:
          runs-on: docker
          needs: [build]
      @IF@
          container:
            image: docker:27-cli
            options: -v /var/run/docker.sock:/var/run/docker.sock
          steps:
            - run: |
                docker pull -q "${IMAGE}:@PROMOTE@"
                docker tag "${IMAGE}:@PROMOTE@" "${IMAGE}:staging"
                docker push -q "${IMAGE}:staging"
                echo "staging is now ${IMAGE}:@PROMOTE@"
      YAML
      if [ "$fault" = race ]; then
        sed -i.bak '/^@IF@$/d' .forgejo/workflows/release.yml
      else
        sed -i.bak "s/^@IF@\$/    if: github.ref == 'refs\/heads\/main'/" .forgejo/workflows/release.yml
      fi
      sed -i.bak -e "s|@KEY@|${key}|" -e "s|@GATE@|${gate}|" -e "s|@PROMOTE@|${promote}|g" .forgejo/workflows/release.yml
      rm -f .forgejo/workflows/release.yml.bak

      git add -A
      git commit -qm "release 1.4: charge for every unit; build once, gate on the test matrix"
      git push -q origin HEAD:main
      r14=$(git rev-parse HEAD)
      wait_deploy "$r14"

      # The digest, not the name, and the two test files as release 1.4 shipped them:
      # the tests are right in every variant, and editing them is how a red is hidden.
      {
        printf '%s' "$fault" | sha256sum | awk '{print $1}'
        sha256sum src/cart.test.js | awk '{print $1}'
        sha256sum src/discount.test.js | awk '{print $1}'
      } > "$drill/state"

      # The hotfix branch was cut from 1.3 for a customer still on it, and deploys
      # with 1.3's pipeline — which writes staging from any branch it runs on.
      if [ "$fault" = race ]; then
        git checkout -q -b hotfix/discount-message "$r13"
        sed -i.bak 's/discount must be between 0 and/discount has to be between 0 and/' src/cart.js && rm -f src/cart.js.bak
        git commit -qam "hotfix: clearer discount error"
        git push -q origin hotfix/discount-message 2>/dev/null
        wait_deploy "$(git rev-parse HEAD)"
      fi

      cat > "$drill/smoke.sh" <<'SH'
      #!/bin/sh
      # Runs the release smoke test inside whatever image staging points at.
      docker run --rm -i --pull always 127.0.0.1:5000/checkout:staging node - <<'JS'
      const { cartTotal } = require("./src/cart");
      const fails = [];
      const check = (name, fn) => { try { const r = fn(); if (r) fails.push(`${name}: ${r}`); } catch (e) { fails.push(`${name}: ${e.constructor.name}: ${e.message}`); } };
      check("3 x 9.50", () => { const t = cartTotal([{ price: 9.5, qty: 3 }]); return t === 28.5 ? "" : `total ${t}, expected 28.5`; });
      check("10% off 100.00", () => { const t = cartTotal([{ price: 100, qty: 1 }], 10); return t === 90 ? "" : `total ${t}, expected 90`; });
      try { cartTotal([{ price: 100, qty: 1 }], 60); fails.push("60% off 100.00: accepted, and the cap is 50%"); }
      catch (e) { if (!(e instanceof RangeError)) fails.push(`60% off 100.00: ${e.constructor.name}: ${e.message}`); }
      console.log(fails.length ? "smoke: FAIL\n  " + fails.join("\n  ") : "smoke: ok");
      process.exit(fails.length ? 1 : 0);
      JS
      SH
      chmod +x "$drill/smoke.sh"

      # Prove the fault took, so a scenario that came up wrong is not graded as one.
      if sh "$drill/smoke.sh" >/dev/null 2>&1; then
        echo "the seeded fault ($fault) did not break staging" >&2
        exit 1
      fi

      echo "scenario ready"
      echo
      echo "  Main's release run passed its gate and deployed to staging."
      echo "  Staging is broken. That's the ticket."
      echo
      echo "  forge:     http://localhost:3000   (devops / devopslings)"
      echo "  registry:  http://localhost:5000   (staging is checkout:staging)"
      echo "  smoke:     sh $drill/smoke.sh"
      echo "  answer:    $drill/answers/triage.md"
      echo
      echo "  git clone http://devops:devopslings@localhost:3000/devops/checkout.git"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 900
    run: |
      api="http://127.0.0.1:3000/api/v1"
      auth="-u devops:devopslings"
      repo="devops/checkout"
      remote="http://devops:devopslings@127.0.0.1:3000/${repo}.git"
      reg="http://127.0.0.1:5000"
      accept='application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'
      drill="$(cd ../.. && pwd)/scratch/pipeline-triage-drill"

      digest=$(sed -n 1p "$drill/state" 2>/dev/null || true)
      fault=""
      for cand in tests gate cache race stale; do
        [ "$(printf '%s' "$cand" | sha256sum | awk '{print $1}')" = "$digest" ] && fault=$cand
      done
      if [ -z "$fault" ]; then
        echo "not yet: $drill/state does not name a seeded fault. Start the lesson"
        echo "         again — the scenario has to seed one before it can be graded."
        exit 1
      fi

      # ---- helpers ------------------------------------------------------------
      # Every lookup may legitimately find nothing (a tag never pushed, a job that
      # never ran), so each absorbs its own failure instead of tripping set -e.
      tasks() { curl -fsS $auth "${api}/repos/${repo}/actions/tasks?limit=50" 2>/dev/null | tr '{' '\n' || true; }
      # "name=status" for each job of a commit's newest run, newest entry per name.
      jobs_of() {
        tasks | grep "\"head_sha\":\"$1\"" \
          | sed -n 's/.*"name":"\([^"]*\)".*"status":"\([a-z]*\)".*/\1=\2/p' | awk -F= '!seen[$1]++' || true
      }
      # Waits until every job of a commit's run has settled. Empty if nothing ran.
      settle() {
        _out=""
        for _ in $(seq 60); do
          _out=$(jobs_of "$1")
          if [ -n "$_out" ] && ! printf '%s\n' "$_out" | grep -qE '=(running|waiting|blocked)$'; then
            # Jobs that wait on others can appear late; settled means unchanged.
            sleep 5
            [ "$(jobs_of "$1")" = "$_out" ] && break
          fi
          sleep 5
        done
        printf '%s' "$_out"
      }
      tag_digest() {
        curl -fsS -H "Accept: ${accept}" -o /dev/null -D - "${reg}/v2/checkout/manifests/$1" 2>/dev/null \
          | grep -i '^docker-content-digest:' | tr -d '\r' | awk '{print $2}' || true
      }
      label_sha() {
        _cfg=$(curl -fsS -H "Accept: ${accept}" "${reg}/v2/checkout/manifests/$1" 2>/dev/null \
                 | tr -d ' \n' | sed -n 's/.*"config":{[^}]*"digest":"\(sha256:[0-9a-f]*\)".*/\1/p' || true)
        [ -n "$_cfg" ] || return 0
        curl -fsS "${reg}/v2/checkout/blobs/${_cfg}" 2>/dev/null \
          | tr ',' '\n' | sed -n 's/.*"git.sha":"\([0-9a-f]*\)".*/\1/p' | head -1 || true
      }
      # The logs of every test job in a commit's run, concatenated.
      test_logs() {
        _run=$(tasks | grep "\"head_sha\":\"$1\"" | sed -n 's/.*"run_number":\([0-9]*\).*/\1/p' | head -1 || true)
        [ -n "$_run" ] || return 0
        for _j in 0 1 2 3 4 5 6 7; do
          _l=$(curl -fsS $auth "http://127.0.0.1:3000/${repo}/actions/runs/${_run}/jobs/${_j}/logs" 2>/dev/null || true)
          case "$_l" in *" of job test"*) printf '%s\n' "$_l" ;; esac
        done
        return 0
      }
      # The grader's own copy of the smoke test, run in an image pinned by digest.
      smoke() {
        docker run --rm -i "127.0.0.1:5000/checkout@$1" node - 2>&1 <<'JS' || true
      const { cartTotal } = require("./src/cart");
      const fails = [];
      const check = (name, fn) => { try { const r = fn(); if (r) fails.push(`${name}: ${r}`); } catch (e) { fails.push(`${name}: ${e.constructor.name}: ${e.message}`); } };
      check("3 x 9.50", () => { const t = cartTotal([{ price: 9.5, qty: 3 }]); return t === 28.5 ? "" : `total ${t}, expected 28.5`; });
      check("10% off 100.00", () => { const t = cartTotal([{ price: 100, qty: 1 }], 10); return t === 90 ? "" : `total ${t}, expected 90`; });
      try { cartTotal([{ price: 100, qty: 1 }], 60); fails.push("60% off 100.00: accepted, and the cap is 50%"); }
      catch (e) { if (!(e instanceof RangeError)) fails.push(`60% off 100.00: ${e.constructor.name}: ${e.message}`); }
      console.log(fails.length ? "smoke: FAIL\n  " + fails.join("\n  ") : "smoke: ok");
      JS
      }

      # ---- the grader's clone, and putting back what its probes move ----------
      work=$(mktemp -d)
      base_sha=""
      staging_0=""
      probed=""
      cleanup() {
        curl -fsS $auth -X DELETE "${api}/repos/${repo}/branches/hotfix%2Fgrader-probe" >/dev/null 2>&1 || true
        if [ -n "$probed" ] && [ -n "$base_sha" ]; then
          git -C "$work/checkout" push -q --force "$remote" "${base_sha}:main" >/dev/null 2>&1 || true
        fi
        # A probe that deployed moved the staging tag; point it back at the
        # manifest it held before the check started.
        if [ -n "$staging_0" ] && [ "$(tag_digest staging)" != "$staging_0" ]; then
          _ct=$(curl -fsS -H "Accept: ${accept}" -o /dev/null -D - "${reg}/v2/checkout/manifests/${staging_0}" 2>/dev/null \
                  | grep -i '^content-type:' | tr -d '\r' | awk '{print $2}' || true)
          curl -fsS -H "Accept: ${accept}" "${reg}/v2/checkout/manifests/${staging_0}" -o "$work/manifest" 2>/dev/null \
            && curl -fsS -X PUT -H "Content-Type: ${_ct}" --data-binary "@$work/manifest" \
                 "${reg}/v2/checkout/manifests/staging" >/dev/null 2>&1 || true
        fi
        rm -rf "$work"
      }
      trap cleanup EXIT

      if ! git clone -q "$remote" "$work/checkout" 2>/dev/null; then
        echo "not yet: could not clone devops/checkout from the forge"
        exit 1
      fi
      cd "$work/checkout"
      git config user.email grader@example.invalid
      git config user.name grader
      base_sha=$(git rev-parse HEAD)

      # ---- the tests are the tests --------------------------------------------
      # Including the herring: a test skipped on purpose, in every log, that looks
      # like the reason staging was never checked.
      if ! grep -q 'skip: "nightly only' src/discount.test.js 2>/dev/null; then
        echo "not yet: 'live pricing service agrees with the cart' is no longer skipped in"
        echo "         src/discount.test.js. It is skipped by design: it needs the staging"
        echo "         pricing service, which only the nightly job can reach, and nothing"
        echo "         about the release depends on it. Put it back as it was."
        exit 1
      fi
      line=2
      for f in cart discount; do
        want=$(sed -n "${line}p" "$drill/state" 2>/dev/null || true)
        line=$((line + 1))
        if [ "$(sha256sum "src/$f.test.js" 2>/dev/null | awk '{print $1}')" != "$want" ]; then
          echo "not yet: src/$f.test.js on main is not the file release 1.4 shipped. The"
          echo "         tests were right; a suite edited until it agrees with the build"
          echo "         proves nothing about it. Put the file back and fix what it tests."
          exit 1
        fi
      done

      # ---- the pipeline is still the pipeline ---------------------------------
      wf=$(cat .forgejo/workflows/*.yml .forgejo/workflows/*.yaml 2>/dev/null | grep -v '^[[:space:]]*#' || true)
      if [ -z "$wf" ]; then
        echo "not yet: there is no workflow in .forgejo/workflows on main"
        exit 1
      fi
      case "$wf" in
        *matrix:*) ;;
        *)
          echo "not yet: the workflow no longer runs the test matrix. Collapsing the shards"
          echo "         changes what the pipeline is; the drill is to repair it."
          exit 1
          ;;
      esac
      case "$wf" in
        *actions/cache*) ;;
        *)
          echo "not yet: the workflow no longer caches its dependencies. Deleting the cache"
          echo "         is honest and slow; keep it, and make it honest."
          exit 1
          ;;
      esac
      builds=$(printf '%s\n' "$wf" | grep -cE 'docker (buildx )?build' || true)
      if [ "${builds:-0}" -ne 1 ]; then
        echo "not yet: the workflow runs 'docker build' ${builds:-0} times. Staging has to"
        echo "         get the one image the run built, promoted by its tag, not a second"
        echo "         build of the same commit."
        exit 1
      fi

      # ---- the tip of main reached staging ------------------------------------
      jobs=$(settle "$base_sha")
      deploy=$(printf '%s\n' "$jobs" | sed -n 's/^deploy-staging=//p' | head -1)
      if [ "$deploy" != success ]; then
        echo "not yet: deploy-staging on the tip of main (${base_sha}) is '${deploy:-not run}'."
        echo "         Every job of that run:"
        printf '%s\n' "${jobs:-(no run at all)}" | sed 's/^/           /'
        echo "         A release that stops before staging has not been repaired."
        exit 1
      fi

      staging_0=$(tag_digest staging)
      running=$(label_sha staging)
      if [ "$running" != "$base_sha" ]; then
        if [ -z "$running" ]; then
          where="an image with no git.sha label"
        elif git merge-base --is-ancestor "$running" "$base_sha" 2>/dev/null; then
          where="${running}, an older commit on main"
        elif git cat-file -e "${running}^{commit}" 2>/dev/null; then
          where="${running}, which is not on main"
        else
          where="${running}, a commit this clone does not have"
        fi
        echo "not yet: main is at ${base_sha} and staging is running ${where}."
        echo "         The tip's deploy-staging succeeded, so staging was either written"
        echo "         after it or written with some other image. Find out which."
        exit 1
      fi
      if [ "$staging_0" != "$(tag_digest "$base_sha")" ]; then
        echo "not yet: staging carries the tip's git.sha label, and its manifest is not the"
        echo "         one the build pushed as checkout:${base_sha}. Same commit, two images:"
        echo "         staging is not running what CI built."
        exit 1
      fi

      out=$(smoke "$staging_0")
      case "$out" in
        "smoke: ok"*) ;;
        *)
          echo "not yet: staging runs the tip of main, and the smoke test against it fails:"
          printf '%s\n' "$out" | sed 's/^/           /'
          exit 1
          ;;
      esac

      # ---- and CI ran the suite that would have said so ------------------------
      logs=$(test_logs "$base_sha")
      pass=$(printf '%s\n' "$logs" | sed -n 's/.*# pass \([0-9]*\).*/\1/p' | awk '{s += $1} END {print s + 0}')
      failed=$(printf '%s\n' "$logs" | sed -n 's/.*# fail \([0-9]*\).*/\1/p' | awk '{s += $1} END {print s + 0}')
      if [ "${pass:-0}" -lt 5 ] || [ "${failed:-0}" -ne 0 ]; then
        echo "not yet: staging works, and the test jobs on the tip of main report ${pass:-0}"
        echo "         passing and ${failed:-0} failing. The two shards hold five tests that run"
        echo "         and pass, plus one skipped by design. A pipeline that runs fewer is the"
        echo "         same green that shipped the bug."
        exit 1
      fi

      # ---- the fault is closed where it lives ---------------------------------
      probe() {
        git add -A
        git commit -qm "$1"
        if ! git push -q "$remote" "HEAD:$2" 2>/dev/null; then
          echo "not yet: the grader could not push its probe commit to $2"
          exit 1
        fi
        probed=1
        probe_sha=$(git rev-parse HEAD)
        probe_jobs=$(settle "$probe_sha")
      }

      case "$fault" in
        gate)
          printf '\ntest("grader: a total that is wrong", () => {\n  assert.strictEqual(cartTotal([]), 1);\n});\n' >> src/cart.test.js
          probe "grader: a commit whose cart tests fail" main
          shard=$(printf '%s\n' "$probe_jobs" | sed -n 's/^test (cart)=//p' | head -1)
          gate=$(printf '%s\n' "$probe_jobs" | sed -n 's/^gate=//p' | head -1)
          pdeploy=$(printf '%s\n' "$probe_jobs" | sed -n 's/^deploy-staging=//p' | head -1)
          if [ "$shard" != failure ]; then
            echo "not yet: the grader pushed a commit with a failing cart test, and the cart"
            echo "         shard reported '${shard:-nothing}'."
            exit 1
          fi
          if [ "$pdeploy" = success ]; then
            echo "not yet: the grader pushed a commit whose cart shard failed, and"
            echo "         deploy-staging ran anyway (gate: '${gate:-none}'). 'needs:' orders jobs;"
            echo "         it does not carry their verdict, and 'if: always()' runs the gate"
            echo "         whatever the shards did. The gate has to read the result."
            exit 1
          fi
          ;;
        cache)
          if ! printf '%s\n' "$wf" | grep -E 'key:' | grep -q 'hashFiles(.*package-lock'; then
            echo "not yet: the cache key does not hash package-lock.json. A key that ignores"
            echo "         the lockfile restores old dependencies under a new one; a key that"
            echo "         changes every commit never saves an install. Key it on the lockfile."
            exit 1
          fi
          if grep -q 'pricing-rules-1.0.0' package-lock.json 2>/dev/null; then
            to=2.0.0
            sri="sha512-6+dANMlAkZafwbm4RQt8DpJl+tz6We/jFX+tFxo/rV3gsnpiDlkT8Mu9u3sRMF/lt5/GSDRO0dtnZKe+hr+VYg=="
          else
            to=1.0.0
            sri="sha512-hvPjo0jWmhkfImw8EYixYoZbWpcUg9nQosWwdpmUllSvRO5Cm5dorpuyvmz7K0mwkTVznGBseyJSsosksQK3Cw=="
          fi
          sed -i.bak "s/pricing-rules-[0-9.]*\.tgz/pricing-rules-${to}.tgz/g; s/\"version\": \"[12]\.0\.0\"/\"version\": \"${to}\"/" package-lock.json package.json
          sed -i.bak "s|\"integrity\": \"[^\"]*\"|\"integrity\": \"${sri}\"|" package-lock.json
          rm -f package-lock.json.bak package.json.bak
          probe "grader: change pricing-rules to ${to}, and nothing else" main
          plogs=$(test_logs "$probe_sha")
          if case "$plogs" in *"Cache restored from key"*) true ;; *) false ;; esac; then
            echo "not yet: the grader changed package-lock.json to pricing-rules ${to} and the"
            echo "         test jobs restored a cached node_modules anyway:"
            printf '%s\n' "$plogs" | grep 'Cache restored from key' | sed 's/^[0-9TZ:.-]* /           /' | head -1 || true
            echo "         They tested the old dependency under the new lockfile."
            exit 1
          fi
          ;;
        race)
          git checkout -q -b grader-probe
          echo "grader probe" > GRADER.md
          probe "grader: a hotfix branch" hotfix/grader-probe
          pdeploy=$(printf '%s\n' "$probe_jobs" | sed -n 's/^deploy-staging=//p' | head -1)
          if [ "$pdeploy" = success ] || [ "$(tag_digest staging)" != "$staging_0" ]; then
            echo "not yet: the grader pushed a branch called hotfix/grader-probe and it"
            echo "         deployed to staging over main. Any ref that can write staging can"
            echo "         land last; staging has to come from main and nowhere else."
            exit 1
          fi
          ;;
        stale)
          case "$wf" in
            *:latest*)
              echo "not yet: the workflow still uses the :latest tag. A tag any run can move"
              echo "         says nothing about which build it points at; promote the image by"
              echo "         the commit it was built from."
              exit 1
              ;;
          esac
          echo "grader probe" > GRADER.md
          probe "grader: a commit that should reach staging" main
          pdigest=$(tag_digest "$probe_sha")
          if [ -z "$pdigest" ] || [ "$(tag_digest staging)" != "$pdigest" ]; then
            pdeploy=$(printf '%s\n' "$probe_jobs" | sed -n 's/^deploy-staging=//p' | head -1)
            echo "not yet: the grader pushed a commit to main and staging did not move to the"
            echo "         image built for it (deploy-staging: '${pdeploy:-not run}'). Staging is"
            echo "         right now because it was put right, not because the pipeline does it."
            exit 1
          fi
          ;;
      esac

      # ---- naming it ----------------------------------------------------------
      ans="$drill/answers/triage.md"
      if [ ! -s "$ans" ]; then
        echo "not yet: $ans is missing or empty. Staging works;"
        echo "         now say what it was: cause:, evidence:, detection: lines."
        exit 1
      fi
      low=$(tr 'A-Z' 'a-z' < "$ans")
      field() { printf '%s\n' "$low" | sed -n "s/^[[:space:]]*$1[[:space:]]*[:=][[:space:]]*//p" | awk 'NR==1'; }
      a_cause=$(field cause); a_ev=$(field evidence); a_det=$(field detection)

      c_tests='\b(if-present|npm run test|test script|tests script|scripts?|no tests|never ran|ran no tests)\b'
      c_gate='\b(gate|gated|gating)\b|\bneeds(\.|:)|always\(\)'
      c_cache='\b(cache|cached|cache key|lockfile|package-lock|hashfiles|node_modules)\b'
      c_race='\b(hotfix|branch|ref|race|raced|unmerged)\b'
      c_stale='\b(latest|mutable|retag|retagged)\b'

      case "$fault" in
        tests)
          what="the package.json script is 'tests', the workflow runs 'npm run test --if-present', and --if-present turns the missing script into a pass: CI ran no tests, so the quantity bug shipped"
          c_re=$c_tests
          e_re='\b(logs?|summary|package\.json|if-present|scripts?|missing script)\b|# (pass|tests)'
          e_say="the test job's log with no '# tests' summary in it, and package.json's script name"
          d_re='\b(test count|tests ran|tests run|number of tests|pass count|summary|zero tests|no tests)\b|# (pass|tests)'
          d_say="the number of tests each run executed, alerting when it drops" ;;
        gate)
          what="the gate job runs with if: always() and never reads needs.test.result, so the release deployed with the cart shard red"
          c_re=$c_gate
          e_re='\b(shards?|failure|failed|red|jobs?|statuses|actions)\b'
          e_say="the run itself: test (cart) failed, and gate, build and deploy-staging succeeded after it"
          d_re='\b(failed (jobs?|shards?)|failures?|failing|red|shards?|deploy(ed|s)? (with|after|despite))\b'
          d_say="any deploy from a run that has a failed job, which should be zero" ;;
        cache)
          what="the dependency cache key ignored package-lock.json, so CI restored pricing-rules 1.0.0 after the lockfile moved to 2.0.0, while the image installed 2.0.0"
          c_re=$c_cache
          e_re='\b(cache restored|restored|cache-hit|cache hit|key|node_modules|npm ls|version)\b'
          e_say="'Cache restored from key: deps-Linux' in the test log of the commit that changed the lockfile"
          d_re='\b(cache|cache-hit|cache hit|lockfile|hash|versions?|mismatch|drift)\b'
          d_say="a mismatch between the lockfile and what CI installed, or a cache hit on a lockfile change" ;;
        race)
          what="a hotfix branch, deploying with 1.3's pipeline, wrote staging after main's deploy, so staging ran a commit that is not on main"
          c_re=$c_race
          e_re='\b(git\.sha|label|labels|branch|merge-base|contains|config|tasks|runs?|head_branch)\b'
          e_say="the git.sha label on the staging image, and git branch --contains for that commit"
          d_re='\b(sha|commit|not on main|branch|ref|mismatch|drift|differs?|different|behind|tip)\b'
          d_say="staging's git.sha not being the tip of main for longer than a deploy takes" ;;
        stale)
          what="deploy-staging promoted :latest, which the 1.4 build no longer pushes, so staging kept 1.3's image"
          c_re=$c_stale
          e_re='\b(latest|digest|digests|git\.sha|label|manifest|pull)\b'
          e_say="the staging digest matching :latest rather than the tip's tag, or its git.sha label"
          d_re='\b(sha|commit|digest|mismatch|drift|age|stale|differs?|different|behind|tip)\b'
          d_say="staging's git.sha not being the tip of main for longer than a deploy takes" ;;
      esac

      hits=0
      for re in "$c_tests" "$c_gate" "$c_cache" "$c_race" "$c_stale"; do
        printf '%s' "$a_cause" | grep -Eq "$re" && hits=$((hits + 1))
      done

      fail=0
      if [ -z "$a_cause" ]; then
        fail=1; echo "not yet: no cause: line in $ans."
      elif [ "$hits" -ge 3 ]; then
        fail=1; echo "not yet: the cause line names several different mechanisms. Name the one."
      elif ! printf '%s' "$a_cause" | grep -Eq "$c_re"; then
        fail=1
        echo "not yet: cause says '${a_cause}', and staging works, so something was"
        echo "         repaired. What was seeded:"
        echo "         $what."
      fi
      if [ -z "$a_ev" ] || ! printf '%s' "$a_ev" | grep -Eq "$e_re"; then
        fail=1
        echo "not yet: evidence says '${a_ev:-nothing}'. For this fault the proof is"
        echo "         $e_say."
      fi
      if [ -z "$a_det" ] || ! printf '%s' "$a_det" | grep -Eq "$d_re"; then
        fail=1
        echo "not yet: detection says '${a_det:-nothing}'. Name a signal that would have"
        echo "         caught it before staging did: $d_say."
      elif ! printf '%s' "$a_det" | grep -q '[0-9]'; then
        fail=1
        echo "not yet: detection names a signal and no threshold. Say at what number it"
        echo "         fires — 'fewer than 5 tests ran', 'drift for more than 10 minutes'."
      fi
      [ "$fail" -eq 0 ] || exit 1

      echo "PASS — the seeded fault ($fault) was closed in the pipeline, staging runs the"
      echo "       image CI built for the tip of main, the suite ran, the nightly-only"
      echo "       test is still skipped, and triage.md names it."
---
