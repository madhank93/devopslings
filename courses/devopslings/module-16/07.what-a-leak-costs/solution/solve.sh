#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Issue, store, revoke — where "revoke" means the identity, not just the token.
# The attacker traded the leaked token for a registry credential, and that one
# outlives the token. It does not outlive the account it was issued to.
set -euo pipefail

api="http://127.0.0.1:3000/api/v1"
auth="-u devops:devopslings"
new=deploy-bot-2
newpass="$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"

# 1. Issue: a fresh service account, and a token for it.
curl -fsS $auth -X POST "${api}/admin/users" -H 'Content-Type: application/json' \
  -d "{\"username\":\"${new}\",\"email\":\"${new}@example.invalid\",\"password\":\"${newpass}\",\"must_change_password\":false}" \
  >/dev/null
token=$(curl -fsS -u "${new}:${newpass}" -X POST "${api}/users/${new}/tokens" \
  -H 'Content-Type: application/json' \
  -d '{"name":"deploy","scopes":["read:user","write:package"]}' \
  | sed -n 's/.*"sha1":"\([0-9a-f]*\)".*/\1/p')

# 2. Store it where the pipeline reads it.
curl -fsS $auth -X PUT "${api}/repos/devops/checkout/actions/secrets/DEPLOY_TOKEN" \
  -H 'Content-Type: application/json' -d "{\"data\":\"${token}\"}" >/dev/null

# 3. Revoke: delete the old account. Its tokens die with it, and so does every
#    registry credential issued to it.
curl -fsS $auth -X DELETE "${api}/admin/users/deploy-bot?purge=true" >/dev/null
