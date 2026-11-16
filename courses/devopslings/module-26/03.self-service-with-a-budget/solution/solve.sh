#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# create stamps an expiry at the TTL, extend moves it for a stated reason, and
# reap runs every minute and removes whatever has expired.
set -euo pipefail

api="http://127.0.0.1:3000/api/v1"
auth="-u devops:devopslings"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git clone -q "http://devops:devopslings@127.0.0.1:3000/devops/environments.git" "$work/e"
cd "$work/e"
git config user.email devops@example.invalid
git config user.name devops
mkdir -p ci

cat > ci/envs.js <<'JS'
// Preview environment lifecycle: node ci/envs.js create|extend|reap.
// Inputs come from the environment (NAME, OWNER, HOURS, REASON, ACTOR).
const fs = require("node:fs");

const { ttl_hours, max_extension_hours } = JSON.parse(fs.readFileSync("platform.json", "utf8"));
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d+Z$/, "Z");
const file = (name) => `envs/${name}.json`;
const fail = (m) => { console.error(`::error::${m}`); process.exit(1); };
// Environments from before expiry existed end at created + TTL.
const expiry = (e) => Date.parse(e.expires || "") || Date.parse(e.created) + ttl_hours * 3600e3;

const { NAME, OWNER, HOURS, REASON, ACTOR } = process.env;
switch (process.argv[2]) {
  case "create": {
    if (!/^[a-z0-9-]+$/.test(NAME || "")) fail("name must be lowercase letters, digits and dashes");
    const now = Date.now();
    const env = { name: NAME, owner: OWNER, created: iso(now), expires: iso(now + ttl_hours * 3600e3),
                  url: `http://${NAME}.preview.internal` };
    fs.writeFileSync(file(NAME), JSON.stringify(env, null, 2) + "\n");
    console.log(`${NAME} expires ${env.expires}`);
    break;
  }
  case "extend": {
    if (!fs.existsSync(file(NAME))) fail(`no environment called ${NAME}`);
    if (!(REASON || "").trim()) fail("an extension needs a reason");
    const hours = Number(HOURS);
    if (!(hours > 0 && hours <= max_extension_hours)) fail(`hours must be between 1 and ${max_extension_hours}`);
    const env = JSON.parse(fs.readFileSync(file(NAME), "utf8"));
    env.expires = iso(expiry(env) + hours * 3600e3);
    env.extensions = [...(env.extensions || []), { by: ACTOR, at: iso(Date.now()), hours, reason: REASON.trim() }];
    fs.writeFileSync(file(NAME), JSON.stringify(env, null, 2) + "\n");
    console.log(`${NAME} now expires ${env.expires}`);
    break;
  }
  case "reap": {
    for (const f of fs.readdirSync("envs").filter((f) => f.endsWith(".json"))) {
      const env = JSON.parse(fs.readFileSync(`envs/${f}`, "utf8"));
      if (expiry(env) <= Date.now()) {
        fs.unlinkSync(`envs/${f}`);
        console.log(`reclaimed ${env.name} (owner ${env.owner}, expired ${iso(expiry(env))})`);
      }
    }
    break;
  }
  default:
    fail("usage: envs.js create|extend|reap");
}
JS

# commit-and-push, shared by the three workflows: retries over each other's pushes.
cat > ci/push.sh <<'SH'
#!/bin/sh
# push.sh MESSAGE — commit envs/ and push to main, rebasing over concurrent pushes.
set -e
git add -A envs
git diff --cached --quiet && exit 0
git commit -qm "$1 [skip ci]"
for i in 1 2 3 4 5 6; do
  git push -q origin HEAD:main && exit 0
  sleep "$i"
  git pull -q --rebase origin main
done
exit 1
SH
chmod +x ci/push.sh

# job HEADER STEP-ENV COMMAND MESSAGE
job_steps() {
  cat <<YML
jobs:
  run:
    runs-on: docker
    steps:
      - env:
          TOKEN: \${{ secrets.GITHUB_TOKEN }}
$1
        run: |
          git clone -q "http://x:\${TOKEN}@forge:3000/\${{ github.repository }}.git" r && cd r
          git config user.email platform-bot@example.invalid
          git config user.name platform-bot
          node ci/envs.js $2
          sh ci/push.sh "$3"
YML
}

{ cat <<'YML'
name: create

# Make a preview environment: Actions → create → Run workflow. It expires
# platform.json's ttl_hours after creation unless someone extends it.
on:
  workflow_dispatch:
    inputs:
      name:
        description: environment name, e.g. pr-1422-checkout
        required: true
      owner:
        description: who it is for
        required: true

YML
  job_steps '          NAME: ${{ inputs.name }}
          OWNER: ${{ inputs.owner }}' create 'create ${NAME} for ${OWNER}'
} > .forgejo/workflows/create.yml

{ cat <<'YML'
name: extend

# Keep an environment longer: needs a reason, at most max_extension_hours at a time.
on:
  workflow_dispatch:
    inputs:
      name:
        description: environment to keep
        required: true
      hours:
        description: hours to add to its expiry
        required: true
      reason:
        description: why it is still needed
        required: true

YML
  job_steps '          NAME: ${{ inputs.name }}
          HOURS: ${{ inputs.hours }}
          REASON: ${{ inputs.reason }}
          ACTOR: ${{ github.actor }}' extend 'extend ${NAME} by ${HOURS}h: ${REASON}'
} > .forgejo/workflows/extend.yml

{ cat <<'YML'
name: reap

# Remove every environment past its expiry.
on:
  schedule:
    - cron: "* * * * *"
  workflow_dispatch:

YML
  job_steps '' reap 'reclaim expired environments'
} > .forgejo/workflows/reap.yml

sed -i.bak 's/^\*\*Done with one?\*\*.*/**Expiry:** every environment expires `ttl_hours` after creation and is removed by `reap`. Need it longer? Actions → `extend`, with a reason./' README.md
rm -f README.md.bak

git add -A
git commit -qm "environments expire at the TTL; extend with a reason; reap on a schedule"
git push -q origin HEAD:main

# Reclaim the backlog now rather than at the next minute.
curl -fsS $auth -X POST "${api}/repos/devops/environments/actions/workflows/reap.yml/dispatches" \
  -H 'Content-Type: application/json' -d '{"ref":"main"}' >/dev/null
for _ in $(seq 1 60); do
  n=$(curl -fsS $auth "${api}/repos/devops/environments/contents/envs?ref=main" | grep -o '"type":"file"' | wc -l | tr -d ' ')
  [ "$n" -le 6 ] && exit 0
  sleep 3
done
echo "reap did not reclaim the backlog (still ${n} environments)" >&2
exit 1
