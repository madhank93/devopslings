---
kind: lesson
title: "The leaked token was rotated, and the attacker is still in"
description: |
  Module 12's deploy token, again — but this time it is a real forge token with
  a real account behind it. The team rotated it: new token, new secret, green
  pipeline. The red team kept everything they took while it was public. The
  leak is closed when none of it works, and the deploy still does.
name: what-a-leak-costs
slug: what-a-leak-costs
createdAt: "2026-10-14"

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
      repo="devops/checkout"
      bot=deploy-bot
      botpass=deploy-bot-vault-7731
      kit="${DEVOPSLINGS_ROOT}/scratch/what-a-leak-costs/red-team"

      # ---- clean slate ------------------------------------------------------------
      # Protection rules from other lessons would refuse the seed force-push.
      for rule in $(curl -fsS $auth "${api}/repos/${repo}/branch_protections" 2>/dev/null \
                      | tr ',' '\n' | sed -n 's/.*"rule_name":"\([^"]*\)".*/\1/p' \
                      | sed 's/%/%25/g; s/ /%20/g; s/\*/%2A/g; s/?/%3F/g; s/\[/%5B/g; s/]/%5D/g; s|/|%2F|g' || true); do
        curl -fsS $auth -X DELETE "${api}/repos/${repo}/branch_protections/${rule}" >/dev/null 2>&1 || true
      done

      # A wrong answer may have deleted the repo or made it private.
      if ! curl -fsS $auth "${api}/repos/${repo}" >/dev/null 2>&1; then
        curl -fsS $auth -X POST "${api}/user/repos" -H 'Content-Type: application/json' \
          -d '{"name":"checkout","auto_init":true,"default_branch":"main","private":false}' >/dev/null
      fi
      curl -fsS $auth -X PATCH "${api}/repos/${repo}" -H 'Content-Type: application/json' \
        -d '{"private":false}' >/dev/null

      # Every deploy-bot* account from an earlier attempt goes, with whatever
      # tokens and registry credentials it held.
      for u in $(curl -fsS $auth "${api}/admin/users?limit=100" 2>/dev/null \
                   | tr ',' '\n' | sed -n 's/.*"login":"\([^"]*\)".*/\1/p' | grep '^deploy-bot' || true); do
        curl -fsS $auth -X DELETE "${api}/admin/users/${u}?purge=true" >/dev/null 2>&1 || true
      done

      # ---- the service account and its two tokens ---------------------------------
      curl -fsS $auth -X POST "${api}/admin/users" -H 'Content-Type: application/json' \
        -d "{\"username\":\"${bot}\",\"email\":\"${bot}@example.invalid\",\"password\":\"${botpass}\",\"must_change_password\":false}" \
        >/dev/null

      mint() {
        curl -fsS -u "${bot}:${botpass}" -X POST "${api}/users/${bot}/tokens" \
          -H 'Content-Type: application/json' \
          -d "{\"name\":\"$1\",\"scopes\":[\"read:user\",\"write:package\"]}" \
          | sed -n 's/.*"sha1":"\([0-9a-f]*\)".*/\1/p'
      }
      leaked=$(mint deploy)
      current=$(mint deploy-rotated)
      if [ -z "$leaked" ] || [ -z "$current" ]; then
        echo "could not mint the deploy-bot tokens" >&2
        exit 1
      fi

      # ---- what the attacker did while it was public -------------------------------
      # Logged in, then traded the token for a registry credential. The trade is
      # the whole lesson: that credential is a separate thing with its own life.
      rm -rf "$kit"
      mkdir -p "$kit"
      bearer=$(curl -fsS -u "${bot}:${leaked}" "http://127.0.0.1:3000/v2/token" \
                 | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
      if [ -z "$bearer" ]; then
        echo "could not obtain a registry credential with the leaked token" >&2
        exit 1
      fi
      printf '%s\n' "$leaked" > "$kit/token"
      printf '%s\n' "$bearer" > "$kit/registry-bearer"
      now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      cat > "$kit/NOTES.md" <<MD
      # Red team: deploy-bot

      Taken from the public build log of devops/checkout while the token was
      committed in .forgejo/workflows/deploy.yml.

      - token            the deploy-bot access token, as committed
      - registry-bearer  what the forge's registry handed back for it

      ${now}  GET /api/v1/user   (Authorization: token <token>)          200 deploy-bot
      ${now}  GET /v2/token      (basic auth deploy-bot:<token>)         200 -> registry-bearer

      Replay any of it:

        curl -H "Authorization: token \$(cat token)" http://localhost:3000/api/v1/user
        curl -u "deploy-bot:\$(cat token)" http://localhost:3000/v2/token
        curl -X POST -H "Authorization: Bearer \$(cat registry-bearer)" \\
          http://localhost:3000/v2/deploy-bot/checkout/blobs/uploads/
      MD

      # ---- the repo: the leak, then the rotation everyone stopped at -------------
      curl -fsS $auth -X PUT "${api}/repos/${repo}/actions/secrets/DEPLOY_TOKEN" \
        -H 'Content-Type: application/json' -d "{\"data\":\"${current}\"}" >/dev/null

      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT
      git clone -q "http://devops:devopslings@127.0.0.1:3000/${repo}.git" "$work/c"
      cd "$work/c"
      git config user.email devops@example.invalid
      git config user.name devops
      git rm -rq --ignore-unmatch . >/dev/null
      mkdir -p src .forgejo/workflows

      cat > src/deploy.js <<'JS'
      // Pretends to deploy: proves DEPLOY_TOKEN logs in to the forge and to its
      // registry, which is everything a real deploy of this repo would need.
      const token = process.env.DEPLOY_TOKEN || "";
      const base = "http://forge:3000";

      async function main() {
        if (!token) {
          console.error("FATAL: DEPLOY_TOKEN is not set");
          process.exit(1);
        }
        const me = await fetch(`${base}/api/v1/user`, {
          headers: { Authorization: `token ${token}` },
        });
        if (!me.ok) {
          console.error(`FATAL: the forge rejected DEPLOY_TOKEN: HTTP ${me.status}`);
          process.exit(1);
        }
        const login = (await me.json()).login;
        console.log(`authenticated as ${login}`);

        const basic = Buffer.from(`${login}:${token}`).toString("base64");
        const reg = await fetch(`${base}/v2/token`, {
          headers: { Authorization: `Basic ${basic}` },
        });
        if (!reg.ok) {
          console.error(`FATAL: the registry refused DEPLOY_TOKEN: HTTP ${reg.status}`);
          process.exit(1);
        }
        console.log("registry login ok");
        console.log("deployed ok");
      }

      main();
      JS

      cat > .forgejo/workflows/deploy.yml <<YAML
      name: deploy

      on: [push, workflow_dispatch]

      env:
        DEPLOY_TOKEN: "${leaked}"

      jobs:
        deploy:
          runs-on: docker
          steps:
            - run: git clone -q http://forge:3000/devops/checkout.git . && git checkout -q \${{ github.sha }}
            - run: node src/deploy.js
      YAML

      cat > README.md <<'MD'
      # checkout

      `node src/deploy.js` needs DEPLOY_TOKEN, a deploy-bot access token.
      MD

      git add -A
      git commit -qm "add deploy step"

      # The module 12 fix: literal out, secret in, new value. Not revoked.
      cat > .forgejo/workflows/deploy.yml <<'YAML'
      name: deploy

      on: [push, workflow_dispatch]

      jobs:
        deploy:
          runs-on: docker
          steps:
            - run: git clone -q http://forge:3000/devops/checkout.git . && git checkout -q ${{ github.sha }}
            - run: node src/deploy.js
              env:
                DEPLOY_TOKEN: ${{ secrets.DEPLOY_TOKEN }}
      YAML
      git commit -qam "rotate DEPLOY_TOKEN, read it from repository secrets"
      git push -q origin HEAD:main --force

      echo "scenario ready — the token was rotated, and the red team kept what they took:"
      echo
      echo "  ${kit}"
      echo "  http://localhost:3000/devops/checkout   (devops / devopslings)"
      echo "  deploy-bot's password, from the team vault: ${botpass}"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 600
    run: |
      api="http://127.0.0.1:3000/api/v1"
      auth="-u devops:devopslings"
      repo="devops/checkout"
      kit="${DEVOPSLINGS_ROOT}/scratch/what-a-leak-costs/red-team"
      leaked=$(cat "$kit/token" 2>/dev/null || true)
      bearer=$(cat "$kit/registry-bearer" 2>/dev/null || true)
      if [ -z "$leaked" ] || [ -z "$bearer" ]; then
        echo "not yet: ${kit} is missing or empty — the check replays what is in it."
        echo "         Reset the lesson to put it back."
        exit 1
      fi

      # curl without -f: a refusal is the answer being graded, not an error.
      status() { curl -s -o /dev/null -w '%{http_code}' "$@" 2>/dev/null || true; }

      # ---- 1. the token itself, both ways a client sends it ----------------------
      a=$(status -H "Authorization: token ${leaked}" "${api}/user")
      b=$(status -u "deploy-bot:${leaked}" "${api}/user")
      if [ "$a" = 200 ] || [ "$b" = 200 ]; then
        echo "not yet: the leaked token still logs in — GET /api/v1/user with red-team/token returns 200."
        # Each wrong move leaves its own trace; name the ones that are present.
        if [ "$(status "${api}/repos/${repo}")" != 200 ]; then
          echo "         devops/checkout is no longer publicly readable (private, or deleted). That changes who can read"
          echo "         the repo from now on; the token was copied while it was public."
        fi
        if [ "$(status -u deploy-bot:deploy-bot-vault-7731 "${api}/user")" != 200 ]; then
          echo "         deploy-bot's password has changed. An access token is a separate"
          echo "         credential and a password change does not touch it."
        fi
        echo "         A new token beside it makes the deploy work; only deleting this one makes it stop."
        exit 1
      fi

      # ---- 2. the trade the attacker would make next ------------------------------
      c=$(status -u "deploy-bot:${leaked}" "http://127.0.0.1:3000/v2/token")
      if [ "$c" = 200 ]; then
        echo "not yet: the registry still exchanges red-team/token for a credential (GET /v2/token → 200)."
        exit 1
      fi

      # ---- 3. the trade the attacker already made ---------------------------------
      hdrs=$(curl -s -o /dev/null -D - -X POST -H "Authorization: Bearer ${bearer}" \
               "http://127.0.0.1:3000/v2/deploy-bot/checkout/blobs/uploads/" 2>/dev/null || true)
      code=$(printf '%s\n' "$hdrs" | sed -n 's/^HTTP\/[0-9.]* \([0-9]*\).*/\1/p' | tail -1)
      if [ "$code" = 202 ]; then
        # Abandon the upload the probe just opened.
        loc=$(printf '%s\n' "$hdrs" | tr -d '\r' | sed -n 's/^[Ll]ocation: *//p' | head -1 || true)
        case "$loc" in
          http*) curl -s -o /dev/null -X DELETE -H "Authorization: Bearer ${bearer}" "$loc" 2>/dev/null || true ;;
          /*)    curl -s -o /dev/null -X DELETE -H "Authorization: Bearer ${bearer}" "http://127.0.0.1:3000${loc}" 2>/dev/null || true ;;
        esac
        echo "not yet: the token is dead, and red-team/registry-bearer still opens an image upload"
        echo "         as deploy-bot (POST /v2/deploy-bot/checkout/blobs/uploads/ → 202)."
        echo "         The attacker traded the token for that credential while it was live, and"
        echo "         revoking the token did not revoke what it was traded for. Read NOTES.md."
        exit 1
      fi

      # ---- 4. and the deploy still works ------------------------------------------
      # The check starts its own run, so it grades the secret as it is now,
      # not as it was at the last push.
      last=$(curl -fsS $auth "${api}/repos/${repo}/actions/tasks?limit=50" 2>/dev/null \
               | tr '{' '\n' | sed -n 's/^"id":\([0-9]*\),.*/\1/p' | sort -n | tail -1 || true)
      d=$(status $auth -X POST "${api}/repos/${repo}/actions/workflows/deploy.yml/dispatches" \
            -H 'Content-Type: application/json' -d '{"ref":"main"}')
      if [ "$d" != 204 ]; then
        echo "not yet: could not start .forgejo/workflows/deploy.yml on main (HTTP ${d})."
        echo "         The check runs the deploy itself: keep the file, and keep workflow_dispatch in its on: list."
        exit 1
      fi
      run=""
      state=""
      for _ in $(seq 60); do
        row=$(curl -fsS $auth "${api}/repos/${repo}/actions/tasks?limit=50" 2>/dev/null \
                | tr '{' '\n' | grep '"event":"workflow_dispatch"' | head -1 || true)
        id=$(printf '%s' "$row" | sed -n 's/^"id":\([0-9]*\),.*/\1/p')
        if [ -n "$id" ] && [ "$id" -gt "${last:-0}" ]; then
          run=$(printf '%s' "$row" | sed -n 's/.*"run_number":\([0-9]*\).*/\1/p')
          state=$(printf '%s' "$row" | sed -n 's/.*"status":"\([a-z]*\)".*/\1/p')
          case "$state" in success|failure|cancelled|skipped) break ;; esac
        fi
        sleep 3
      done
      if [ -z "$run" ]; then
        echo "not yet: the deploy run the check started never appeared — is the runner up?"
        exit 1
      fi
      logs=$(curl -fsS $auth "http://127.0.0.1:3000/${repo}/actions/runs/${run}/jobs/0/logs" 2>/dev/null || true)
      who=$(printf '%s\n' "$logs" | sed -n 's/.*authenticated as \([A-Za-z0-9._-]*\).*/\1/p' | head -1)

      if [ "$state" != success ]; then
        echo "not yet: the leak is closed, and the deploy is broken (run #${run}: ${state:-unfinished})."
        case "$logs" in
          *"DEPLOY_TOKEN is not set"*)
            echo "         There is no DEPLOY_TOKEN secret on the repo." ;;
          *"rejected DEPLOY_TOKEN: HTTP 401"*)
            echo "         The forge rejects the token in the DEPLOY_TOKEN secret (401): it was revoked,"
            echo "         or the account it belonged to is gone. Issue the replacement first." ;;
          *"rejected DEPLOY_TOKEN: HTTP 403"*)
            echo "         The forge knows the token and refuses its account (403): that account is"
            echo "         blocked from signing in, so its new token is blocked too." ;;
          *"registry refused DEPLOY_TOKEN"*)
            echo "         The token in the secret logs in as ${who:-?} but the registry refuses it —"
            echo "         a deploy token needs the write:package scope." ;;
          *)
            echo "         Read the run's log: http://localhost:3000/${repo}/actions/runs/${run}" ;;
        esac
        exit 1
      fi
      if [ "$who" = devops ]; then
        echo "not yet: the deploy now runs as devops, the forge's administrator."
        echo "         The next leak of DEPLOY_TOKEN would cost the whole forge. Give it a service account."
        exit 1
      fi

      echo "PASS — nothing the red team took still works, and run #${run} deployed as ${who}."
---
