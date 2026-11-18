---
kind: lesson
title: "The single replica that reached production twice"
description: |
  Twice this year a production service shipped with one replica, and a
  routine node drain took it down. The fix both times was a line on the review
  checklist. A third one is on main right now, and the checklist was ticked.
  Turn the rule into a check that fails the build, with an exception path for
  the service that really does need one replica, and an expiry on it.
name: paved-road-guardrail
slug: paved-road-guardrail
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

      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT
      mkdir -p "$work/d/services" "$work/d/policy" "$work/d/ci" "$work/d/.forgejo/workflows"
      cd "$work/d"

      svc() {  # svc NAME ENV REPLICAS
        cat > "services/$1.json" <<JSON
      {
        "service": "$1",
        "environment": "$2",
        "replicas": $3,
        "image": "registry.internal/$1@sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
      }
      JSON
      }
      svc checkout production 3
      svc ledger production 2
      svc batch-reporter production 1
      svc search-staging staging 1
      svc search production 1

      cat > ci/validate.js <<'JS'
      // Every file under services/ is JSON with the fields the deployer reads.
      const fs = require("node:fs");
      let bad = 0;
      for (const f of fs.readdirSync("services").filter((f) => f.endsWith(".json"))) {
        try {
          const s = JSON.parse(fs.readFileSync(`services/${f}`, "utf8"));
          for (const k of ["service", "environment", "image"]) {
            if (!s[k]) { console.error(`${f}: missing ${k}`); bad++; }
          }
        } catch (e) {
          console.error(`${f}: ${e.message}`); bad++;
        }
      }
      if (bad) process.exit(1);
      console.log("services: valid");
      JS

      cat > .forgejo/workflows/validate.yml <<'YML'
      name: validate

      on: [push]

      jobs:
        validate:
          runs-on: docker
          steps:
            - run: git clone -q "http://forge:3000/${{ github.repository }}.git" . && git checkout -q ${{ github.sha }}
            - run: node ci/validate.js
      YML

      cat > policy/exceptions.json <<'JSON'
      []
      JSON

      cat > policy/README.md <<'MD'
      # Exceptions

      An exception lets one service break one rule, for a while. Each entry in
      `exceptions.json`:

      ```json
      {
        "service": "batch-reporter",
        "rule": "min-replicas",
        "reason": "why this service cannot follow the rule",
        "expires": "YYYY-MM-DD"
      }
      ```

      `expires` is required and is at most 90 days away. On that date the
      exception stops applying, and either the service follows the rule or
      someone renews the exception, with a reason, in review.

      Rules:

      | rule | what it requires |
      |---|---|
      | `min-replicas` | a service with `"environment": "production"` runs at least 2 replicas |
      MD

      cat > CONTRIBUTING.md <<'MD'
      # Review checklist

      Before approving a change under `services/`:

      - [ ] The image is pinned by digest
      - [ ] Production services run at least 2 replicas (added after INC-2291)
      - [ ] **Production services run at least 2 replicas** (added again after INC-2417)
      MD

      cat > INCIDENTS.md <<'MD'
      # Incidents caused by deploy config

      | | date | what happened |
      |---|---|---|
      | INC-2291 | 2026-05-12 | `ledger` shipped with `replicas: 1`. A kernel-patch drain took its only pod; 11 minutes of failed payments. |
      | INC-2417 | 2026-09-03 | `checkout` shipped with `replicas: 1` in a config refactor. Same drain, 7 minutes. |

      `batch-reporter` runs one replica on purpose: it holds a lock on the nightly
      export and two copies would run it twice. That is the only one.
      MD

      git init -q -b main
      git config user.email devops@example.invalid
      git config user.name devops
      git add -A
      git commit -qm "deploy config for five services"
      curl -fsS $auth -X POST "${api}/user/repos" -H 'Content-Type: application/json' \
        -d '{"name":"deployments","default_branch":"main","private":false}' >/dev/null
      git push -q "${base}/deployments.git" main

      echo "scenario ready — devops/deployments: search is about to ship with one replica, and CI is green"
      echo
      echo "  http://localhost:3000/devops/deployments   (devops / devopslings)"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 600
    run: |
      docker run --rm -i --network devopslings-ci-net node:22-bookworm bash -s <<'CHECK'
      set -u
      api="http://forge:3000/api/v1"
      auth="-u devops:devopslings"
      work=$(mktemp -d)
      git clone -q "http://devops:devopslings@forge:3000/devops/deployments.git" "$work/d" 2>/dev/null || {
        echo "not yet: devops/deployments could not be cloned."; exit 1; }
      cd "$work/d"
      git config user.email platform-check@example.invalid
      git config user.name platform-check

      drop_probes() {
        for b in $(git ls-remote --heads origin 'probe/*' 2>/dev/null | sed 's|.*refs/heads/||'); do
          git push -q origin --delete "$b" >/dev/null 2>&1 || true
        done
      }
      trap 'drop_probes; rm -rf "$work"' EXIT
      drop_probes

      # status SHA — wait for the commit's combined status.
      status() {
        local s=""
        for _ in $(seq 1 100); do
          s=$(curl -s $auth "${api}/repos/devops/deployments/commits/$1/status" | sed -n 's/^{"state":"\([a-z]*\)".*/\1/p')
          case "$s" in success|failure|error) break ;; esac
          sleep 3
        done
        printf '%s' "${s:-none}"
      }

      # 1. main itself.
      main=$(git rev-parse HEAD)
      node - <<'JS' || exit 1
      const fs = require("node:fs");
      const no = (m) => { console.log(`not yet: ${m}`); process.exit(1); };
      const read = (f) => { try { return JSON.parse(fs.readFileSync(f, "utf8")); } catch (e) { no(`${f} on main is missing or not valid JSON: ${e.message}`); } };
      const search = read("services/search.json");
      if (!(search.replicas >= 2)) no(`services/search.json on main still has replicas: ${search.replicas}. That is the third\n         occurrence, and it is on main now; the guardrail is for the fourth.`);
      for (const f of ["checkout", "ledger", "batch-reporter"]) {
        if (!fs.existsSync(`services/${f}.json`)) no(`services/${f}.json is gone from main. The guardrail has to let the real services ship.`);
      }
      const br = read("services/batch-reporter.json");
      if (br.replicas !== 1) no(`batch-reporter runs ${br.replicas} replicas on main. It holds the nightly export's lock;\n         two copies run the export twice. It needs its exception, not a second replica.`);
      const ex = read("policy/exceptions.json");
      if (!Array.isArray(ex)) no("policy/exceptions.json is not a JSON array.");
      const e = ex.find((x) => x && x.service === "batch-reporter" && x.rule === "min-replicas");
      if (!e) no("policy/exceptions.json has no min-replicas exception for batch-reporter.");
      if (!e.reason || String(e.reason).trim().length < 15) no("batch-reporter's exception has no reason worth the name. The reason is what the next reviewer renews or refuses.");
      const days = (Date.parse(e.expires) - Date.now()) / 864e5;
      if (!(days > 0 && days <= 91)) no(`batch-reporter's exception expires "${e.expires}". It needs a date in the next 90 days.`);
      JS
      s=$(status "$main")
      if [ "$s" != success ]; then
        echo "not yet: the pipeline for main (${main:0:8}) is '${s}'. The real services, with batch-reporter's"
        echo "         exception, have to ship. What the pipeline said:"
        run=$(curl -s $auth "${api}/repos/devops/deployments/actions/tasks?limit=50" | tr '{' '\n' | grep "$main" \
          | sed -n 's/.*"run_number":\([0-9]*\).*/\1/p' | head -1)
        [ -n "$run" ] && curl -s $auth "http://forge:3000/devops/deployments/actions/runs/${run}/jobs/0/logs" \
          | sed -E 's/^[0-9TZ:.-]+ //' | LC_ALL=C grep -vE '^(local\(version|workflow prepared|Cleaning up|Job |[^ -~]|[[:space:]]|$)' \
          | tail -4 | sed 's/^/           /'
        exit 1
      fi

      # 2. The guardrail, probed: one branch per case, each a commit on top of main.
      #    probe NAME ENV REPLICAS EXPIRES-IN-DAYS(""=no exception, "none"=no expires field)
      declare -A want desc sha
      probe() {
        local id=$1
        git checkout -q -B "probe/$id" "$main"
        node - "$@" <<'JS'
      const fs = require("node:fs");
      const [id, env, replicas, exp] = process.argv.slice(2);
      const s = { service: `probe-${id}`, environment: env, image: `registry.internal/probe-${id}@sha256:${"a".repeat(64)}` };
      if (replicas !== "omit") s.replicas = Number(replicas);
      fs.writeFileSync(`services/probe-${id}.json`, JSON.stringify(s, null, 2) + "\n");
      if (exp !== "") {
        const ex = JSON.parse(fs.readFileSync("policy/exceptions.json", "utf8"));
        const e = { service: `probe-${id}`, rule: "min-replicas", reason: "probe from the platform check: a singleton by design" };
        if (exp !== "none") e.expires = new Date(Date.now() + Number(exp) * 864e5).toISOString().slice(0, 10);
        ex.push(e);
        fs.writeFileSync("policy/exceptions.json", JSON.stringify(ex, null, 2) + "\n");
      }
      JS
        git add -A
        git commit -qm "probe: $id"
        git push -q -f origin "probe/$id" 2>/dev/null
        sha[$id]=$(git rev-parse HEAD)
      }
      probe one          production 1    ""    ; want[one]=failure;     desc[one]="a production service with replicas: 1 and no exception"
      probe missing      production omit ""    ; want[missing]=failure; desc[missing]="a production service with no replicas field at all (the deployer defaults it to 1)"
      probe excepted     production 1    30    ; want[excepted]=success; desc[excepted]="a production service with replicas: 1 and a min-replicas exception expiring in 30 days"
      probe expired      production 1    -1    ; want[expired]=failure; desc[expired]="a production service with replicas: 1 whose exception expired yesterday"
      probe forever      production 1    none  ; want[forever]=failure; desc[forever]="a production service with replicas: 1 whose exception has no expires date"
      probe far          production 1    400   ; want[far]=failure;     desc[far]="a production service with replicas: 1 whose exception expires in 400 days"
      probe staging      staging    1    ""    ; want[staging]=success; desc[staging]="a staging service with replicas: 1"
      git checkout -q main

      for id in one missing excepted expired forever far staging; do
        got=$(status "${sha[$id]}")
        if [ "$got" = none ]; then
          echo "not yet: a push to the branch probe/$id never got a pipeline run. The guardrail has to run on"
          echo "         every branch, before the merge, or it reviews what is already in production."
          exit 1
        fi
        if [ "$got" != "${want[$id]}" ]; then
          if [ "${want[$id]}" = failure ]; then
            echo "not yet: the pipeline passed ${desc[$id]}."
            case $id in
              missing) echo "         A missing field is not a satisfied rule: undefined < 2 is false in JavaScript." ;;
              expired) echo "         An exception with a date nobody checks is a permanent exception." ;;
              forever) echo "         An exception without an expiry is a permanent exception." ;;
              far)     echo "         policy/README.md says at most 90 days; past that it is a permanent exception with a date on it." ;;
            esac
          else
            echo "not yet: the pipeline refused ${desc[$id]}."
            case $id in
              excepted) echo "         The documented exception has to work for any service that files one, not only batch-reporter." ;;
              staging)  echo "         min-replicas is a production rule. A guardrail that blocks the wrong thing gets routed around." ;;
            esac
          fi
          exit 1
        fi
      done

      echo "PASS — main is green with search at 2+ replicas; the guardrail refused 5 bad configs and allowed 2 good ones."
      CHECK
---
