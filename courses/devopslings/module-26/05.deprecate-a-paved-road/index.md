---
kind: lesson
title: "Thirty services on a build that cannot fail"
description: |
  v1 of the platform's shared build swallows test failures, and thirty
  services use it. v2 fixes it. The last deprecation was an email with a date,
  and on the date half the company's builds went red at once. Move all thirty
  to v2 without a single red build on main, and leave a check that proves
  nobody is still on v1.
name: deprecate-a-paved-road
slug: deprecate-a-paved-road
createdAt: "2026-11-16"

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

      # Module 26's repos, from this lesson or another one.
      page=1
      while :; do
        names=$(curl -fsS $auth "${api}/users/devops/repos?limit=50&page=${page}" 2>/dev/null \
                  | tr ',' '\n' | sed -n 's/^"name":"\([^"]*\)"$/\1/p' || true)
        [ -n "$names" ] || break
        for r in $names; do
          case "$r" in
            service-template|orders|deployments|environments|paved-road|svc-[0-9]*|gp-*|payments*)
              curl -fsS $auth -X DELETE "${api}/repos/devops/${r}" >/dev/null 2>&1 || true ;;
          esac
        done
        page=$((page + 1))
        [ "$page" -gt 10 ] && break
      done

      docker run --rm -i --network devopslings-ci-net node:22-bookworm bash -s <<'SEED'
      set -euo pipefail
      api="http://forge:3000/api/v1"
      auth="-u devops:devopslings"
      base="http://devops:devopslings@forge:3000/devops"
      mkrepo() {
        curl -fsS $auth -X POST "${api}/user/repos" -H 'Content-Type: application/json' \
          -d "{\"name\":\"$1\",\"default_branch\":\"main\",\"private\":false}" >/dev/null
      }
      gitinit() {
        git init -q -b main
        git config user.email devops@example.invalid
        git config user.name devops
      }

      # The paved road: a composite action, tagged v1 and v2.
      mkdir -p /w/paved-road && cd /w/paved-road && gitinit
      cat > action.yml <<'YML'
      name: paved-road
      description: Build and test a Node service the platform way.
      runs:
        using: composite
        steps:
          - name: test
            shell: bash
            # Flaky-test week, March: keep builds green while the suite settles.
            run: npm test || echo "::warning::tests failed; not failing the build"
      YML
      cat > README.md <<'MD'
      # paved-road

      The platform's build for Node services. In a service's workflow, after the
      clone step:

      ```yaml
      - uses: http://forge:3000/devops/paved-road@v2
      ```

      ## Versions

      - **v2** — test failures fail the build.
      - **v1** — *deprecated.* Swallows test failures: a service on v1 is green
        whatever its tests say. Thirty services are still on it.

      ## Retiring v1

      The last retirement (v0) was an email with a date. On the date the tag was
      deleted and every build still on it failed at once.
      MD
      git add -A && git commit -qm "paved-road v1"
      git tag v1
      cat > action.yml <<'YML'
      name: paved-road
      description: Build and test a Node service the platform way.
      runs:
        using: composite
        steps:
          - name: test
            shell: bash
            run: npm test
      YML
      git add -A && git commit -qm "paved-road v2: test failures fail the build"
      git tag v2
      mkrepo paved-road
      git push -q "${base}/paved-road.git" main v1 v2

      # Thirty consumers. Three have a bug their tests catch, and v1 hides it.
      # Some also use the action from a release workflow, and the reference is
      # not written the same way in every repository.
      for i in $(seq -w 1 30); do
        n="svc-${i}"
        mkdir -p "/w/${n}/src" "/w/${n}/.forgejo/workflows" && cd "/w/${n}" && gitinit
        printf '{\n  "name": "%s",\n  "version": "1.0.0",\n  "scripts": { "test": "node --test" }\n}\n' "$n" > package.json
        case "$i" in
          07|19|26) line='  return items.reduce((sum, i) => sum + i.price, 0);' ;;
          *)        line='  return items.reduce((sum, i) => sum + i.price * i.qty, 0);' ;;
        esac
        printf 'function total(items) {\n%s\n}\n\nmodule.exports = { total };\n' "$line" > src/cart.js
        cat > src/cart.test.js <<'JS'
      const assert = require("node:assert");
      const test = require("node:test");
      const { total } = require("./cart");

      test("total counts quantity", () => {
        assert.strictEqual(total([{ price: 5, qty: 2 }, { price: 1, qty: 3 }]), 13);
      });
      JS
        case "$i" in
          04|22) uses='      - uses: "http://forge:3000/devops/paved-road@v1"' ;;
          11)    uses='      - uses: http://forge:3000/devops/paved-road@v1   # platform build' ;;
          *)     uses='      - uses: http://forge:3000/devops/paved-road@v1' ;;
        esac
        cat > .forgejo/workflows/ci.yml <<YML
      name: ci
      on: [push]
      jobs:
        build:
          runs-on: docker
          steps:
            - run: git clone -q "http://forge:3000/\${{ github.repository }}.git" . && git checkout -q \${{ github.sha }}
      ${uses}
      YML
        case "$i" in
          03|09|15|21|27)
            cat > .forgejo/workflows/release.yml <<'YML'
      name: release
      on: workflow_dispatch
      jobs:
        release:
          runs-on: docker
          steps:
            - run: git clone -q "http://forge:3000/${{ github.repository }}.git" . && git checkout -q ${{ github.sha }}
            - uses: http://forge:3000/devops/paved-road@v1
            - run: echo "release ${{ github.sha }}"
      YML
            ;;
        esac
        git add -A && git commit -qm "${n} [skip ci]"
        mkrepo "$n"
        git push -q "${base}/${n}.git" main
      done
      SEED

      echo "scenario ready — devops/svc-01 … svc-30 build with devops/paved-road@v1, which cannot fail"
      echo
      echo "  http://localhost:3000/devops/paved-road   (devops / devopslings)"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 900
    run: |
      docker run --rm -i --network devopslings-ci-net node:22-bookworm bash -s <<'CHECK'
      set -u
      api="http://forge:3000/api/v1"
      auth="-u devops:devopslings"
      base="http://devops:devopslings@forge:3000/devops"
      work=$(mktemp -d)
      cleanup() {
        for p in svc-98-probe svc-99-probe; do curl -s $auth -X DELETE "${api}/repos/devops/${p}" >/dev/null 2>&1 || true; done
        rm -rf "$work"
      }
      trap cleanup EXIT
      cleanup; mkdir -p "$work"

      status() {  # status REPO SHA [TRIES] — combined commit status, waiting while it runs
        local s="" i
        for i in $(seq 1 "${3:-1}"); do
          s=$(curl -s $auth "${api}/repos/devops/$1/commits/$2/status" | sed -n 's/^{"state":"\([a-z]*\)".*/\1/p')
          case "$s" in success|failure|error) break ;; esac
          [ "${3:-1}" -gt 1 ] && sleep 3
        done
        printf '%s' "${s:-none}"
      }

      # 1. Every consumer: on v2 everywhere, the tests it started with, green on main,
      #    and never red on main.
      for i in $(seq -w 1 30); do
        n="svc-${i}"
        git clone -q "${base}/${n}.git" "$work/$n" 2>/dev/null || {
          echo "not yet: devops/${n} is gone. Migrating a consumer means it still builds afterwards."; exit 1; }
        cd "$work/$n"
        v1=$(grep -lE 'paved-road@v1\b' .forgejo/workflows/* 2>/dev/null | sed 's|^\./||' | tr '\n' ' ' || true)
        if [ -n "$v1" ]; then
          echo "not yet: ${n} still uses paved-road@v1 in: ${v1}"
          left=0
          for j in $(seq -w 1 30); do
            git clone -q "${base}/svc-${j}.git" "$work/c$j" 2>/dev/null && grep -qE 'paved-road@v1\b' "$work/c$j"/.forgejo/workflows/* 2>/dev/null && left=$((left + 1))
          done
          echo "         ${left} of 30 consumers have a workflow on v1."
          exit 1
        fi
        if ! grep -qE 'paved-road@v2\b' .forgejo/workflows/ci.yml 2>/dev/null; then
          echo "not yet: ${n}'s ci.yml no longer builds with paved-road@v2. The consumers move to v2; a"
          echo "         service with no paved-road at all has left the road, not migrated."
          exit 1
        fi
        root=$(git rev-list --max-parents=0 HEAD | tail -1)
        changed=$(git diff --name-only "$root" HEAD -- 'src/*.test.js' package.json | tr '\n' ' ')
        if [ -n "$changed" ]; then
          echo "not yet: ${n} changed ${changed}since it was created. v2 makes failing tests fail the"
          echo "         build; the fix for a red test is the code it caught, not the test."
          exit 1
        fi
        red=$(curl -s $auth "${api}/repos/devops/${n}/actions/tasks?limit=50" | node -e '
          let s = ""; process.stdin.on("data", (d) => (s += d)).on("end", () => {
            const r = (JSON.parse(s).workflow_runs || []).filter((x) => x.head_branch === "main" && x.status === "failure");
            console.log(r.map((x) => x.head_sha.slice(0, 8)).join(" "));
          });')
        if [ -n "$red" ]; then
          echo "not yet: ${n}'s pipeline on main failed (commit ${red}). That is the red build the"
          echo "         migration was meant to avoid: v2 surfaced a real test failure, on main, for"
          echo "         everyone. Run the move on a branch first, and merge it when it is green there."
          echo "         Main's history keeps the red run; reset the lesson to start over."
          exit 1
        fi
        head=$(git rev-parse HEAD)
        s=$(status "$n" "$head" 60)
        if [ "$s" != success ]; then
          echo "not yet: ${n}'s latest commit on main (${head:0:8}) is '${s}' on v2. Every consumer has"
          echo "         to be green on the new version, on main."
          exit 1
        fi
        cd /
      done

      # 2. v2 is still the version that fails on a failing test.
      git clone -q "${base}/svc-07.git" "$work/p2" && cd "$work/p2"
      git config user.email platform-check@example.invalid && git config user.name platform-check
      printf 'function total(items) {\n  return 0;\n}\n\nmodule.exports = { total };\n' > src/cart.js
      curl -s $auth -X POST "${api}/user/repos" -H 'Content-Type: application/json' \
        -d '{"name":"svc-98-probe","default_branch":"main","private":false}' >/dev/null
      git commit -qam "probe: a failing test on v2"
      git push -q "${base}/svc-98-probe.git" HEAD:main 2>/dev/null
      s=$(status svc-98-probe "$(git rev-parse HEAD)" 60)
      if [ "$s" != failure ]; then
        echo "not yet: a service on paved-road@v2 with a failing test is '${s}'. v2 is the version"
        echo "         that fails the build on a failing test; that is the whole point of moving."
        exit 1
      fi
      cd /

      # 3. The check: none on v1 now, and it finds the next one.
      git clone -q "${base}/paved-road.git" "$work/pr" 2>/dev/null
      chk="$work/pr/bin/v1-consumers"
      if [ ! -f "$chk" ]; then
        echo "not yet: devops/paved-road has no bin/v1-consumers. The migration needs a check that"
        echo "         proves no consumer is left on v1, one anyone can rerun."
        exit 1
      fi
      chmod +x "$chk"
      export FORGE_URL=http://forge:3000 FORGE_USER=devops FORGE_PASSWORD=devopslings
      out=$(cd "$work/pr" && timeout 120 "$chk" 2>&1); rc=$?
      if [ "$rc" != 0 ]; then
        echo "not yet: bin/v1-consumers exits ${rc} with every consumer on v2. Its output:"
        printf '%s\n' "$out" | tail -5 | sed 's/^/         /'
        exit 1
      fi
      mkdir -p "$work/p1/.forgejo/workflows" && cd "$work/p1"
      git init -q -b main && git config user.email platform-check@example.invalid && git config user.name platform-check
      cp "$work/svc-01/.forgejo/workflows/ci.yml" "$work/svc-01/package.json" .forgejo/workflows/ 2>/dev/null
      mv .forgejo/workflows/package.json .
      printf 'name: release\non: workflow_dispatch\njobs:\n  release:\n    runs-on: docker\n    steps:\n      - uses: http://forge:3000/devops/paved-road@v1\n' > .forgejo/workflows/release.yml
      git add -A && git commit -qm "probe: v1 in a release workflow [skip ci]"
      curl -s $auth -X POST "${api}/user/repos" -H 'Content-Type: application/json' \
        -d '{"name":"svc-99-probe","default_branch":"main","private":false}' >/dev/null
      git push -q "${base}/svc-99-probe.git" HEAD:main 2>/dev/null
      out=$(cd "$work/pr" && timeout 120 "$chk" 2>&1); rc=$?
      if [ "$rc" = 0 ] || ! printf '%s' "$out" | grep -q 'svc-99-probe'; then
        echo "not yet: a new repository, svc-99-probe, uses paved-road@v1 in .forgejo/workflows/release.yml,"
        echo "         and bin/v1-consumers exits ${rc}$(printf '%s' "$out" | grep -q svc-99-probe || echo ' without naming it')."
        echo "         The check has to find a consumer it has never heard of, in any workflow file."
        exit 1
      fi

      echo "PASS — 30 of 30 consumers green on v2 with no red build on main, v2 fails a failing test, and bin/v1-consumers finds a new v1 consumer."
      CHECK
