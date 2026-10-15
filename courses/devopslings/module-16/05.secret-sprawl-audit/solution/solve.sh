#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The six secrets in the inventory estate, each with where it was found and
# the command that finds it. The decoys beside them are left off on purpose.
set -euo pipefail

cat > "${DEVOPSLINGS_ROOT}/scratch/secret-sprawl-audit/answers/secrets.txt" <<'TXT'
# deploy/inventory.ini on main                 git clone; grep -rn password .
Halyard-mq7-Vesper-22
# .env, added then deleted                     git log -p --all -- .env
lgr_prod_4e1b9c07d2a85f36e0b7
# Actions variable NOTIFY_WEBHOOK_TOKEN        GET /api/v1/repos/devops/inventory/actions/variables
nwh_8c3f02d9b6a14e7f5d21
# DB_PASSWORD in the running container         docker inspect devopslings-inventory-api
Tarn-oxide-5590-quill
# /app/signing.key, removed in a later layer   docker save 127.0.0.1:5000/inventory/api:1.4, untar the layers
isk_1f9a7d3e60b24c8895ce0d17
# access_token in a URL, registry access log   docker logs devopslings-ci-stack-registry-1 | grep token
rlt_c41e9b7a2f6d083e5b
TXT
