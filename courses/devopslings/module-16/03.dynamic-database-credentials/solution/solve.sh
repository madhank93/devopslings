#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
# Runs from sandboxes/ci-stack. OpenBao's database engine issues each service
# its own short-lived Postgres role, and each service reads from its own path.
set -euo pipefail

L=../../courses/devopslings/module-16/03.dynamic-database-credentials
G=$L/services.compose.yaml
dc() { docker compose -f compose.yaml -f "$G" "$@"; }
bao() { dc exec -T -e BAO_TOKEN=devopslings-root bao bao "$@"; }
services="billing orders shipping reports"

bao secrets enable database >/dev/null 2>&1 || true
bao write database/config/app \
  plugin_name=postgresql-database-plugin \
  connection_url='postgresql://{{username}}:{{password}}@db:5432/app?sslmode=disable' \
  username=bao password=bao-admin-pw \
  allowed_roles="billing,orders,shipping,reports" >/dev/null

for s in $services; do
  bao write "database/roles/$s" db_name=app \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' IN ROLE app_rw;" \
    revocation_statements="SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = '{{name}}'; DROP ROLE IF EXISTS \"{{name}}\";" \
    default_ttl=1h max_ttl=24h >/dev/null
  S=$(printf '%s' "$s" | tr '[:lower:]' '[:upper:]')
  sed -i.bak "s|^${S}_DB_CREDS=.*|${S}_DB_CREDS=database/creds/$s|" .env
done
rm -f .env.bak

dc up -d $services >/dev/null 2>&1
