#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
# Runs from sandboxes/ci-stack.
#   1. store the key in OpenBao
#   2. have greeter fetch it from OpenBao when it starts
#   3. take it out of the Dockerfile, and rebuild
set -euo pipefail

L=../../courses/devopslings/module-16/01.store-and-read
G=$L/greeter.compose.yaml
S=../../scratch/store-and-read
dc() { docker compose -f compose.yaml -f "$G" "$@"; }

dc exec -T -e BAO_TOKEN=devopslings-root bao \
  bao kv put secret/greeter/partner-api key=wxp_live_4be1c09f7d2a4e38b6513c8e0f9a27d5 >/dev/null

# Replace load_key() with a fetch from OpenBao's KV v2 API.
awk '
  /^def load_key\(\):/ {
    print "def load_key():"
    print "    req = urllib.request.Request("
    print "        os.environ[\"BAO_ADDR\"] + \"/v1/secret/data/greeter/partner-api\","
    print "        headers={\"X-Vault-Token\": os.environ[\"BAO_TOKEN\"]})"
    print "    with urllib.request.urlopen(req, timeout=5) as resp:"
    print "        return json.load(resp)[\"data\"][\"data\"][\"key\"]"
    skip = 1; next
  }
  skip && /^$/ { skip = 0 }
  skip { next }
  /^import os$/ { print; print "import urllib.request"; next }
  { print }
' "$S/app.py" > "$S/app.py.new"
mv "$S/app.py.new" "$S/app.py"

grep -v '^ENV PARTNER_API_KEY=' "$S/Dockerfile" > "$S/Dockerfile.new"
mv "$S/Dockerfile.new" "$S/Dockerfile"

dc up -d --build greeter >/dev/null 2>&1
