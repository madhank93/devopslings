---
kind: lesson
title: "Forty preview environments, six in use"
description: |
  Developers make preview environments with one click, and nothing ever
  removes one. There are forty, six are in use, and the bill is for forty.
  The platform's answer so far is a message in #platform asking people to
  clean up after themselves. Make environments expire on their own at the
  stated TTL, with a way to keep one longer that needs a reason, not a ticket.
name: self-service-with-a-budget
slug: self-service-with-a-budget
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

      # ana is a developer: she can push and run workflows in the repo, and she
      # is not on the platform team and not an admin.
      curl -fsS $auth -X DELETE "${api}/admin/users/ana?purge=true" >/dev/null 2>&1 || true
      curl -fsS $auth -X POST "${api}/admin/users" -H 'Content-Type: application/json' \
        -d '{"username":"ana","email":"ana@example.invalid","password":"ana-devopslings","must_change_password":false}' >/dev/null
      curl -fsS $auth -X POST "${api}/user/repos" -H 'Content-Type: application/json' \
        -d '{"name":"environments","default_branch":"main","private":false}' >/dev/null
      curl -fsS $auth -X PUT "${api}/repos/devops/environments/collaborators/ana" -H 'Content-Type: application/json' \
        -d '{"permission":"write"}' >/dev/null

      # The registry is generated in the runner's job image, which has node and
      # GNU date whatever the host is.
      docker run --rm -i --network devopslings-ci-net node:22-bookworm bash -s <<'SEED'
      set -euo pipefail
      cd "$(mktemp -d)"
      git init -q -b main
      git config user.email devops@example.invalid
      git config user.name devops
      mkdir -p envs .forgejo/workflows

      cat > platform.json <<'JSON'
      {
        "ttl_hours": 72,
        "max_extension_hours": 168
      }
      JSON

      # Forty environments: thirty-four from the last month that nobody
      # removed, and six from the last day that people are using.
      node <<'JS'
      const fs = require("node:fs");
      const owners = ["ana", "bo", "chen", "dara", "eli", "fatima", "gus", "hana"];
      const services = ["checkout", "search", "ledger", "orders", "billing"];
      const now = Date.now();
      for (let i = 0; i < 40; i++) {
        const hoursAgo = i < 6 ? 2 + i * 3 : 96 + (i - 6) * 19;
        const name = `pr-${1380 + i}-${services[i % services.length]}`;
        const env = {
          name,
          owner: owners[(i * 3) % owners.length],
          created: new Date(now - hoursAgo * 3600e3).toISOString().replace(/\.\d+Z$/, "Z"),
          url: `http://${name}.preview.internal`,
        };
        fs.writeFileSync(`envs/${name}.json`, JSON.stringify(env, null, 2) + "\n");
      }
      JS

      cat > .forgejo/workflows/create.yml <<'YML'
      name: create

      # Make a preview environment: Actions → create → Run workflow.
      on:
        workflow_dispatch:
          inputs:
            name:
              description: environment name, e.g. pr-1422-checkout
              required: true
            owner:
              description: who it is for
              required: true

      jobs:
        create:
          runs-on: docker
          steps:
            - name: register the environment
              env:
                NAME: ${{ inputs.name }}
                OWNER: ${{ inputs.owner }}
                TOKEN: ${{ secrets.GITHUB_TOKEN }}
              run: |
                case "$NAME" in ''|*[!a-z0-9-]*) echo "::error::name must be lowercase letters, digits and dashes"; exit 1 ;; esac
                git clone -q "http://x:${TOKEN}@forge:3000/${{ github.repository }}.git" r && cd r
                git config user.email platform-bot@example.invalid
                git config user.name platform-bot
                node -e '
                  const fs = require("node:fs");
                  const env = {
                    name: process.env.NAME,
                    owner: process.env.OWNER,
                    created: new Date().toISOString().replace(/\.\d+Z$/, "Z"),
                    url: `http://${process.env.NAME}.preview.internal`,
                  };
                  fs.writeFileSync(`envs/${env.name}.json`, JSON.stringify(env, null, 2) + "\n");
                '
                git add envs
                git commit -qm "create ${NAME} for ${OWNER} [skip ci]"
                git push -q origin HEAD:main
      YML

      cat > README.md <<'MD'
      # environments

      Every file in `envs/` is a preview environment that exists. The
      provisioner reconciles the real ones against this directory: add a file
      and the environment comes up, remove it and the environment is torn down.

      **Create one:** Actions → `create` → Run workflow.

      **Done with one?** Please post in #platform and we will remove it.

      `platform.json` holds the platform's limits.
      MD

      cat > COST.md <<'MD'
      # Preview environments, November

      40 environments × €11.40/day. Traffic in the last 7 days: 6 of them.
      MD

      git add -A
      git commit -qm "environments registry"
      git push -q "http://devops:devopslings@forge:3000/devops/environments.git" main
      SEED

      echo "scenario ready — devops/environments: 40 environments, 6 in use"
      echo
      echo "  http://localhost:3000/devops/environments   (devops / devopslings)"
      echo "  developer account: ana / ana-devopslings"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 900
    run: |
      docker run --rm -i --network devopslings-ci-net node:22-bookworm bash -s <<'CHECK'
      set -u
      api="http://forge:3000/api/v1"
      auth="-u devops:devopslings"
      ana="-u ana:ana-devopslings"
      repo=devops/environments
      work=$(mktemp -d)
      id=$(head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')
      fresh="probe-${id}"
      stale="probe-${id}-stale"

      sync() { (cd "$work/e" && git fetch -q origin && git reset -q --hard origin/main) 2>/dev/null; }
      # push_change MSG — commit what is staged, retrying over the workflows' own pushes.
      push_change() {
        (cd "$work/e"
          git commit -qm "$1 [skip ci]" || return 0
          for _ in 1 2 3 4 5 6; do
            git push -q origin HEAD:main 2>/dev/null && return 0
            git pull -q --rebase origin main 2>/dev/null || true
            sleep 2
          done
          return 1)
      }
      cleanup() {
        sync
        (cd "$work/e" && git rm -q --ignore-unmatch "envs/${fresh}.json" "envs/${stale}.json" >/dev/null 2>&1)
        push_change "platform check: remove probes" || true
        rm -rf "$work"
      }
      trap cleanup EXIT

      git clone -q "http://devops:devopslings@forge:3000/${repo}.git" "$work/e" 2>/dev/null || {
        echo "not yet: devops/environments could not be cloned."; exit 1; }
      cd "$work/e"
      git config user.email platform-check@example.invalid
      git config user.name platform-check

      # Read a field of an environment, or "absent".
      field() { node -e 'try { const e = require(process.argv[1]); const v = e[process.argv[2]]; console.log(v === undefined ? "" : (typeof v === "object" ? JSON.stringify(v) : v)); } catch { console.log("absent"); }' "$work/e/envs/$1.json" "$2"; }
      epoch() { node -e 'const t = Date.parse(process.argv[1]); console.log(isNaN(t) ? "" : Math.round(t / 1000))' "$1"; }

      ttl=$(node -p 'require("./platform.json").ttl_hours' 2>/dev/null || echo "")
      maxext=$(node -p 'require("./platform.json").max_extension_hours' 2>/dev/null || echo "")
      if [ "$ttl" != 72 ] || [ "$maxext" != 168 ]; then
        echo "not yet: platform.json says ttl_hours ${ttl:-?} and max_extension_hours ${maxext:-?}. The stated"
        echo "         TTL is 72 hours and an extension is at most 168; reclaim at those numbers."
        exit 1
      fi

      runs() { curl -s $auth "${api}/repos/${repo}/actions/tasks?limit=50"; }
      last_run() { runs | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const r=JSON.parse(s).workflow_runs||[];console.log(Math.max(0,...r.map(x=>x.run_number)))}catch{console.log(0)}})'; }
      # dispatch AUTH WORKFLOW JSON-INPUTS — run it, wait for it to finish, print its status.
      dispatch() {
        local before code st=""
        before=$(last_run)
        code=$(curl -s -o /dev/null -w '%{http_code}' $1 -X POST "${api}/repos/${repo}/actions/workflows/$2/dispatches" \
          -H 'Content-Type: application/json' -d "{\"ref\":\"main\",\"inputs\":$3}")
        if [ "$code" != 204 ]; then echo "dispatch-refused-${code}"; return; fi
        for _ in $(seq 1 60); do
          st=$(runs | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const r=(JSON.parse(s).workflow_runs||[]).filter(x=>x.run_number>+process.argv[1]&&x.event==="workflow_dispatch");console.log(r.length?r[0].status:"")})' "$before")
          case "$st" in success|failure|cancelled|skipped) break ;; esac
          sleep 3
        done
        echo "${st:-never-ran}"
      }

      # 1. The leftovers are gone: nothing older than the TTL survives, and the
      #    six from the last day are still there.
      now=$(date +%s)
      old=0; young=0; legacy_young=0
      for f in envs/*.json; do
        [ -e "$f" ] || continue
        n=$(basename "$f" .json)
        c=$(epoch "$(field "$n" created)")
        [ -n "$c" ] || continue
        if [ $(( now - c )) -gt $(( ttl * 3600 + 300 )) ] && [ -z "$(field "$n" extensions)" ]; then old=$((old + 1)); fi
        case "$n" in pr-13[89]*|pr-14[01]*) [ $(( now - c )) -lt 86400 ] && legacy_young=$((legacy_young + 1)) ;; esac
      done
      if [ "$old" -gt 0 ]; then
        echo "not yet: ${old} environment(s) in envs/ were created more than ${ttl} hours ago and never extended."
        echo "         Asking people to clean up is how there came to be forty. Reclaim them automatically."
        exit 1
      fi
      if [ "$legacy_young" -lt 6 ]; then
        echo "not yet: only ${legacy_young} of the six environments created in the last day are left. The TTL"
        echo "         is 72 hours from creation; those are in use."
        exit 1
      fi

      # 2. A developer creates one, with no help.
      st=$(dispatch "$ana" create.yml "{\"name\":\"${fresh}\",\"owner\":\"ana\"}")
      sync
      if [ "$st" != success ] || [ "$(field "$fresh" name)" = absent ]; then
        echo "not yet: ana (a developer, not an admin) ran create for ${fresh}: '${st}', and envs/${fresh}.json"
        echo "         $( [ "$(field "$fresh" name)" = absent ] && echo 'never appeared' || echo 'appeared')."
        exit 1
      fi
      c=$(epoch "$(field "$fresh" created)"); x=$(epoch "$(field "$fresh" expires)")
      if [ -z "$x" ]; then
        echo "not yet: create made envs/${fresh}.json with no expires time (an ISO date in an \"expires\""
        echo "         field). An environment with no end date is the forty you started with."
        exit 1
      fi
      if [ $(( x - c - ttl * 3600 )) -gt 600 ] || [ $(( x - c - ttl * 3600 )) -lt -600 ]; then
        echo "not yet: create set ${fresh} to expire $(( (x - c) / 3600 )) hours after it was created; the TTL is ${ttl}."
        exit 1
      fi

      # 3. Extending needs a reason, and nothing else.
      dispatch "$ana" extend.yml "{\"name\":\"${fresh}\",\"hours\":\"24\",\"reason\":\"\"}" >/dev/null
      sync
      x1=$(epoch "$(field "$fresh" expires)")
      if [ "$x1" != "$x" ]; then
        echo "not yet: extend with an empty reason moved ${fresh}'s expiry by $(( (x1 - x) / 3600 )) hours. An"
        echo "         extension without a reason is a TTL nobody has to justify."
        exit 1
      fi
      reason="customer demo on Thursday, needs it until then"
      st=$(dispatch "$ana" extend.yml "{\"name\":\"${fresh}\",\"hours\":\"48\",\"reason\":\"${reason}\"}")
      sync
      x2=$(epoch "$(field "$fresh" expires)")
      if [ "$st" = dispatch-refused-404 ] || [ "$st" = never-ran ]; then
        echo "not yet: ana could not run .forgejo/workflows/extend.yml (${st}). The extension path is a"
        echo "         workflow a developer runs with the inputs name, hours and reason."
        exit 1
      fi
      if [ -z "$x2" ] || [ $(( x2 - x - 48 * 3600 )) -gt 600 ] || [ $(( x2 - x - 48 * 3600 )) -lt -600 ]; then
        echo "not yet: ana extended ${fresh} by 48 hours with a reason, and its expiry moved by"
        echo "         $(( (${x2:-$x} - x) / 3600 )) hours (run: ${st})."
        exit 1
      fi
      if ! grep -qF "$reason" "envs/${fresh}.json"; then
        echo "not yet: the 48-hour extension went through, and envs/${fresh}.json does not record its reason."
        echo "         The reason is the audit trail: who kept what, and why."
        exit 1
      fi
      dispatch "$ana" extend.yml "{\"name\":\"${fresh}\",\"hours\":\"500\",\"reason\":\"we would like to keep it a while\"}" >/dev/null
      sync
      x3=$(epoch "$(field "$fresh" expires)")
      if [ -n "$x3" ] && [ $(( x3 - x2 )) -gt $(( maxext * 3600 + 600 )) ]; then
        echo "not yet: one extension of 500 hours moved ${fresh}'s expiry by $(( (x3 - x2) / 3600 )) hours. One"
        echo "         extension is at most ${maxext}; past that, extending again is the point of review."
        exit 1
      fi

      # 4. Reclaiming happens on a schedule, not when someone remembers.
      node - "$stale" <<'JS'
      const fs = require("node:fs");
      const name = process.argv[2];
      const iso = (h) => new Date(Date.now() + h * 3600e3).toISOString().replace(/\.\d+Z$/, "Z");
      fs.writeFileSync(`envs/${name}.json`, JSON.stringify({
        name, owner: "platform-check", created: iso(-100), expires: iso(-28), url: `http://${name}.preview.internal`,
      }, null, 2) + "\n");
      JS
      git add "envs/${stale}.json"
      push_change "platform check: an environment that expired yesterday" || { echo "not yet: could not push to ${repo}."; exit 1; }
      pushed=$(date +%s)
      gone=no
      for _ in $(seq 1 60); do
        sync
        if [ ! -e "envs/${stale}.json" ]; then gone=yes; break; fi
        sleep 4
      done
      if [ "$gone" = no ]; then
        echo "not yet: ${stale} expired yesterday, and four minutes later it is still in envs/."
        sched=$(runs | grep -c '"event":"schedule"' || true)
        [ "$sched" = 0 ] && echo "         No workflow in ${repo} has run on a schedule."
        exit 1
      fi
      by=$(runs | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const r=(JSON.parse(s).workflow_runs||[]).filter(x=>x.event==="schedule"&&x.status==="success"&&Date.parse(x.updated_at||x.created_at)/1000>=+process.argv[1]);console.log(r.length)})' "$pushed")
      if [ "$by" = 0 ]; then
        echo "not yet: ${stale} was removed, and no scheduled run finished after it was pushed. Something"
        echo "         removed it, and it was not the schedule. Reclaiming has to happen with nobody watching."
        exit 1
      fi
      if [ ! -e "envs/${fresh}.json" ]; then
        echo "not yet: the reaper also removed ${fresh}, which expires in days. Reclaim at the expiry, not before."
        exit 1
      fi

      echo "PASS — 40 became $(ls envs/*.json | grep -vc probe-) by TTL; ana created, extended with a reason, and the schedule reclaimed an expired one."
      CHECK
---
