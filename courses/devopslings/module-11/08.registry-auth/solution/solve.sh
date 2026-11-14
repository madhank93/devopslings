#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
# A dedicated account, readable on shop/ only, and production logged in as it.
set -euo pipefail

reg=127.0.0.1:15000
cfg=/etc/registry/config.json
htpasswd -Bb /etc/registry/htpasswd robot-prod-pull 'pull-only-6c1d' 2>/dev/null
jq '.http.accessControl.repositories["shop/**"].policies +=
      [{ "users": ["robot-prod-pull"], "actions": ["read"] }]' "$cfg" > /tmp/config.json
cat /tmp/config.json > "$cfg"
rm -f /tmp/config.json
sleep 3   # zot reloads the file when it changes

DOCKER_CONFIG=/work/runtime/docker crane auth login "$reg" -u robot-prod-pull -p 'pull-only-6c1d'
/work/runtime/deploy.sh "$reg/shop/web:1.4.0"
/work/runtime/deploy.sh "$reg/shop/cart:2.0.1"
