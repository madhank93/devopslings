---
kind: lesson
title: "The template that makes another copy of orders"
description: |
  A new service takes three days, because the way to make one is to copy
  orders and hunt down every place it says orders. Someone made a template.
  Every service generated from it is still called orders, and its pipeline is
  red before anyone has written a line. Make generating a service the whole
  job: a green pipeline, a dashboard and an alert, with no manual step.
name: golden-path-template
slug: golden-path-template
createdAt: "2026-11-16"

sandbox:
  stack: ci-stack
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 600
    run: |
      api="http://127.0.0.1:3000/api/v1"
      auth="-u devops:devopslings"
      base="http://devops:devopslings@127.0.0.1:3000/devops"

      # Module 26's repos, from this lesson or another one, plus any service a
      # student generated while trying this one.
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

      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT

      mkrepo() {  # mkrepo NAME TEMPLATE(true|false)
        curl -fsS $auth -X POST "${api}/user/repos" -H 'Content-Type: application/json' \
          -d "{\"name\":\"$1\",\"default_branch\":\"main\",\"private\":false,\"template\":$2}" >/dev/null
      }

      # orders: the service everyone copies. It is fine as it is.
      mkdir -p "$work/orders/src" "$work/orders/observability" "$work/orders/ci" "$work/orders/.forgejo/workflows"
      cd "$work/orders"

      cat > package.json <<'JSON'
      {
        "name": "orders",
        "version": "1.0.0",
        "scripts": {
          "test": "node --test"
        }
      }
      JSON

      cat > src/health.js <<'JS'
      function health() {
        return { status: "ok" };
      }

      module.exports = { health };
      JS

      cat > src/health.test.js <<'JS'
      const assert = require("node:assert");
      const test = require("node:test");
      const { health } = require("./health");

      test("reports ok", () => {
        assert.deepStrictEqual(health(), { status: "ok" });
      });
      JS

      cat > observability/dashboard.json <<'JSON'
      {
        "uid": "orders",
        "title": "orders — requests, errors, latency",
        "panels": [
          {
            "title": "Requests per second",
            "type": "timeseries",
            "targets": [{ "expr": "sum(rate(http_requests_total{job=\"orders\"}[5m]))" }]
          },
          {
            "title": "Error ratio",
            "type": "timeseries",
            "targets": [{ "expr": "sum(rate(http_requests_total{job=\"orders\",code=~\"5..\"}[5m])) / sum(rate(http_requests_total{job=\"orders\"}[5m]))" }]
          },
          {
            "title": "p99 latency",
            "type": "timeseries",
            "targets": [{ "expr": "histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket{job=\"orders\"}[5m])))" }]
          }
        ]
      }
      JSON

      cat > observability/alerts.yml <<'YML'
      groups:
        - name: orders
          rules:
            - alert: HighErrorRate
              expr: |
                sum(rate(http_requests_total{job="orders",code=~"5.."}[5m]))
                  / sum(rate(http_requests_total{job="orders"}[5m])) > 0.05
              for: 5m
              labels:
                service: orders
                severity: page
              annotations:
                summary: more than 5% of orders requests are failing
                dashboard: http://grafana.internal/d/orders
      YML

      # The platform's check. Every service runs it: it is what stops a
      # dashboard or an alert that watches some other service from shipping.
      cat > ci/check-observability.js <<'JS'
      // Fails the build when the service's dashboard or alerts are not about
      // this service. The service is the repository the pipeline runs in.
      const fs = require("node:fs");

      const name = (process.env.GITHUB_REPOSITORY || "").split("/").pop();
      const problems = [];
      const job = `job="${name}"`;

      const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));
      if (pkg.name !== name) problems.push(`package.json name is "${pkg.name}"`);

      const dash = JSON.parse(fs.readFileSync("observability/dashboard.json", "utf8"));
      if (dash.uid !== name) problems.push(`dashboard uid is "${dash.uid}"`);
      const exprs = (dash.panels || []).flatMap((p) => (p.targets || []).map((t) => t.expr || ""));
      if (exprs.length === 0) problems.push("the dashboard has no queries");
      for (const e of exprs) if (!e.includes(job)) problems.push(`dashboard query does not select ${job}: ${e}`);

      const alerts = fs.readFileSync("observability/alerts.yml", "utf8");
      if (!/^\s*- alert:/m.test(alerts)) problems.push("alerts.yml has no alert rule");
      for (const m of alerts.matchAll(/job="([^"]*)"/g)) {
        if (m[1] !== name) problems.push(`alerts.yml selects job="${m[1]}"`);
      }
      if (!alerts.includes(job)) problems.push(`alerts.yml never selects ${job}`);

      if (problems.length) {
        console.error(`observability: this is ${name}, and`);
        for (const p of problems) console.error(`  - ${p}`);
        process.exit(1);
      }
      console.log(`observability: ok for ${name}`);
      JS

      cat > .forgejo/workflows/ci.yml <<'YML'
      name: ci

      on: [push]

      jobs:
        ci:
          runs-on: docker
          steps:
            - run: git clone -q "http://forge:3000/${{ github.repository }}.git" . && git checkout -q ${{ github.sha }}
            - run: npm test
            - run: node ci/check-observability.js
      YML

      cat > README.md <<'MD'
      # orders

      Order API. Pipeline, dashboard and alert are under `.forgejo/`, and
      `observability/`.
      MD

      git init -q -b main
      git config user.email devops@example.invalid
      git config user.name devops
      git add -A
      git commit -qm "orders service"
      mkrepo orders false
      git push -q "${base}/orders.git" main

      # The template: someone copied orders and ticked "template".
      cp -R "$work/orders" "$work/service-template"
      cd "$work/service-template"
      cat > README.md <<'MD'
      # service-template

      Start a new service from this repository: **New repository → Template:
      devops/service-template**. Then:

      1. Rename `orders` to your service's name in `package.json`.
      2. Change the dashboard's `uid`, `title` and every query's `job=` label in
         `observability/dashboard.json`.
      3. Change the `job=` labels, the group name and `service:` in
         `observability/alerts.yml`, and the dashboard link.
      4. Push, and check the pipeline is green.

      Ask in #platform if anything is red.
      MD
      git add -A
      git commit -qm "service template, from orders"
      mkrepo service-template true
      git push -q "${base}/service-template.git" main

      echo "scenario ready — a service generated from devops/service-template comes out as orders"
      echo
      echo "  http://localhost:3000/devops/service-template   (devops / devopslings)"
      echo "  http://localhost:3000/devops/orders"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 600
    run: |
      # The check runs in the runner's own job image, on the forge's network:
      # node for the JSON, git for the clone, nothing needed on the host.
      docker run --rm -i --network devopslings-ci-net node:22-bookworm bash -s <<'CHECK'
      set -u
      api="http://forge:3000/api/v1"
      auth="-u devops:devopslings"
      name="gp-check-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
      work=$(mktemp -d)
      cleanup() {
        curl -s $auth -X DELETE "${api}/repos/devops/${name}" >/dev/null 2>&1 || true
        rm -rf "$work"
      }
      trap cleanup EXIT

      tmpl=$(curl -s $auth "${api}/repos/devops/service-template" || true)
      if ! printf '%s' "$tmpl" | grep -q '"template":true'; then
        echo "not yet: devops/service-template is missing, or no longer marked as a template."
        echo "         Generating from it is the golden path; it has to stay a template."
        exit 1
      fi

      # Generate a service the way a developer does, then make the developer's
      # first push. Nothing in between: that is the whole golden path.
      code=$(curl -s -o "$work/gen.json" -w '%{http_code}' $auth -X POST \
        "${api}/repos/devops/service-template/generate" -H 'Content-Type: application/json' \
        -d "{\"owner\":\"devops\",\"name\":\"${name}\",\"git_content\":true,\"private\":false}" || true)
      if [ "$code" != 201 ]; then
        echo "not yet: generating a repository from devops/service-template failed (HTTP ${code})."
        exit 1
      fi

      # A just-generated repository can briefly serve an empty tree.
      for _ in $(seq 1 15); do
        rm -rf "$work/svc"
        git clone -q "http://devops:devopslings@forge:3000/devops/${name}.git" "$work/svc" 2>/dev/null \
          && [ -n "$(ls -A "$work/svc" | grep -v '^\.git$')" ] && break
        sleep 2
      done
      [ -d "$work/svc/.git" ] || { echo "not yet: the generated repository ${name} could not be cloned."; exit 1; }
      cd "$work/svc"

      # 1. The generated files are about the new service.
      raw=$(grep -rlE '\$\{?REPO_[A-Z_]*\}?' --exclude-dir=.git . 2>/dev/null | sed 's|^\./||' | tr '\n' ' ' || true)
      if [ -n "$raw" ]; then
        echo "not yet: a service generated from the template still has a literal \$REPO_NAME in: ${raw}"
        echo "         Forgejo expands template variables only in the files that .forgejo/template"
        echo "         lists, one glob per line. Everything else is copied byte for byte."
        exit 1
      fi
      left=$(git grep -lw orders 2>/dev/null | tr '\n' ' ' || true)
      if [ -n "$left" ]; then
        echo "not yet: a service generated from the template (here called ${name}) still says"
        echo "         \"orders\" in: ${left}"
        echo "         A README listing the renames is three days of copying, written down. The"
        echo "         template has to produce the new name itself."
        exit 1
      fi

      node - "$name" <<'JS' || exit 1
      const fs = require("node:fs");
      const name = process.argv[2];
      const job = `job="${name}"`;
      const no = (m) => { console.log(`not yet: ${m}`); process.exit(1); };
      let dash;
      try { dash = JSON.parse(fs.readFileSync("observability/dashboard.json", "utf8")); }
      catch (e) { no(`the generated observability/dashboard.json is missing or not valid JSON: ${e.message}`); }
      if (dash.uid !== name) {
        no(`the generated dashboard's uid is "${dash.uid}", and the service is ${name}.\n` +
           `         A uid is unique per Grafana: two services sharing one overwrite each other's dashboard.`);
      }
      if (!String(dash.title || "").includes(name)) no(`the generated dashboard's title "${dash.title}" does not name ${name}.`);
      const exprs = (dash.panels || []).flatMap((p) => (p.targets || []).map((t) => t.expr || ""));
      if (exprs.length < 3) no(`the generated dashboard has ${exprs.length} queries; the template shipped three (rate, errors, latency).`);
      for (const e of exprs) if (!e.includes(job)) no(`a dashboard query in the generated service does not select ${job}:\n         ${e}`);
      let alerts = "";
      try { alerts = fs.readFileSync("observability/alerts.yml", "utf8"); } catch { no("the generated service has no observability/alerts.yml."); }
      if (!/^\s*- alert:/m.test(alerts)) no("the generated observability/alerts.yml has no alert rule.");
      if (!alerts.includes(job)) no(`the generated alert never selects ${job}, so it watches nothing this service emits.`);
      for (const m of alerts.matchAll(/job="([^"]*)"/g)) if (m[1] !== name) no(`the generated alert selects job="${m[1]}".`);
      if (!new RegExp(`service:\\s*["']?${name}["']?\\s*$`, "m").test(alerts)) no(`the generated alert's service label is not ${name}, so it would page as someone else's.`);
      let pkg = {};
      try { pkg = JSON.parse(fs.readFileSync("package.json", "utf8")); } catch {}
      if (pkg.name !== name) no(`the generated package.json is named "${pkg.name}".`);
      JS

      # 2. The developer's first push goes green, and green means the work ran.
      git config user.email dev@example.invalid
      git config user.name dev
      printf '\nFirst change.\n' >> README.md
      git commit -qam "first change"
      git push -q origin HEAD:main 2>/dev/null || { echo "not yet: could not push to the generated ${name}."; exit 1; }
      sha=$(git rev-parse HEAD)

      state=""
      for _ in $(seq 1 90); do
        state=$(curl -s $auth "${api}/repos/devops/${name}/commits/${sha}/status" | sed -n 's/^{"state":"\([a-z]*\)".*/\1/p')
        case "$state" in success|failure|error) break ;; esac
        sleep 3
      done
      run=$(curl -s $auth "${api}/repos/devops/${name}/actions/tasks?limit=20" | tr '{' '\n' | grep "$sha" \
        | sed -n 's/.*"run_number":\([0-9]*\).*/\1/p' | head -1)
      logs=""
      [ -n "$run" ] && logs=$(curl -s $auth "http://forge:3000/devops/${name}/actions/runs/${run}/jobs/0/logs" || true)
      if [ "$state" != success ]; then
        echo "not yet: the first push to a freshly generated service (${name}) is '${state:-never run}'."
        why=$(printf '%s\n' "$logs" | grep -E 'observability:|  - |not ok|Error' | sed -E 's/^[0-9TZ:.-]+ //' | head -6)
        [ -n "$why" ] && printf '%s\n' "$why" | sed 's/^/         /'
        exit 1
      fi
      pass=$(printf '%s' "$logs" | sed -n 's/.*# pass \([0-9]*\).*/\1/p' | tail -1)
      if [ "${pass:-0}" -lt 1 ]; then
        echo "not yet: ${name}'s pipeline is green and its log shows no test passing. The golden"
        echo "         path's pipeline runs the tests; one that does not is green for nothing."
        exit 1
      fi
      if ! printf '%s' "$logs" | grep -q "observability: ok for ${name}"; then
        echo "not yet: ${name}'s pipeline is green without running ci/check-observability.js."
        echo "         That check is what proves the dashboard and the alert are this service's."
        exit 1
      fi

      echo "PASS — ${name}, generated and pushed once: pipeline green, ${pass} test(s), dashboard and alert are its own."
      CHECK
---
