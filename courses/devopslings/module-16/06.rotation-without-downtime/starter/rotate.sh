#!/usr/bin/env bash
# Rotates the password orders uses for Postgres. Run it from sandboxes/ci-stack.
set -euo pipefail

bao()  { docker compose exec -T -e BAO_TOKEN=devopslings-root bao bao "$@"; }
psql() { docker compose exec -T db psql -U postgres -d app -v ON_ERROR_STOP=1 -qAt "$@"; }

new=$(head -c 18 /dev/urandom | base64 | tr -d '/+=')

psql -c "ALTER ROLE orders PASSWORD '$new'"
bao kv put secret/orders/db username=orders password="$new" >/dev/null

echo "rotated"
