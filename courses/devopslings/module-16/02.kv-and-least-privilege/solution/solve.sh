#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
# Runs from sandboxes/ci-stack. One read-only policy per service, on its own
# KV v2 data path, and one token per service carrying only that policy.
set -euo pipefail

L=../../courses/devopslings/module-16/02.kv-and-least-privilege
G=$L/kv.compose.yaml
dc() { docker compose -f compose.yaml -f "$G" "$@"; }
bao() { dc exec -T -e BAO_TOKEN=devopslings-root bao bao "$@"; }

{
  echo "COMPOSE_FILE=compose.yaml:$G"
  echo "COMPOSE_PROJECT_NAME=devopslings-ci-stack"
} > .env.new

for s in billing orders shipping; do
  printf 'path "secret/data/%s/config" {\n  capabilities = ["read"]\n}\n' "$s" \
    | bao policy write "$s" - >/dev/null
  t=$(bao token create -policy="$s" -field=token | tr -d '\r')
  echo "$(printf '%s' "$s" | tr '[:lower:]' '[:upper:]')_BAO_TOKEN=$t" >> .env.new
done
mv .env.new .env

dc up -d billing orders shipping >/dev/null 2>&1
