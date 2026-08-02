#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Three separate things, and only the first is obvious:
#   1. take the literal out of the workflow and read it from secrets
#   2. store a secret on the repo so the pipeline still authenticates
#   3. ROTATE — the original value has been public since the first push, so
#      moving that same string into a secret store protects nothing
set -euo pipefail

api="http://127.0.0.1:3000/api/v1"
auth="-u devops:devopslings"

# 3. A new value. This is the part people skip.
new_token="dpl_$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"

# 2. Store it where the runner can reach it and the repo cannot leak it.
curl -fsS $auth -X PUT "${api}/repos/devops/checkout/actions/secrets/DEPLOY_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"data\":\"${new_token}\"}" >/dev/null

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git clone -q "http://devops:devopslings@127.0.0.1:3000/devops/checkout.git" "$work/c"
cd "$work/c"
git config user.email devops@example.invalid
git config user.name devops

# 1. Reference the secret instead of the literal, and scope it to the job that
#    needs it rather than the whole workflow.
cat > .forgejo/workflows/deploy.yml <<'YAML'
name: deploy

on: [push]

jobs:
  deploy:
    runs-on: docker
    steps:
      - uses: actions/checkout@v4
      - run: npm run deploy
        env:
          DEPLOY_TOKEN: ${{ secrets.DEPLOY_TOKEN }}
YAML

git add -A
git commit -qm "read DEPLOY_TOKEN from repository secrets"
git push -q origin main
