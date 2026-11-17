#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
# Sign the release by digest, then make the trust policy require that key for
# everything pulled from this registry.
set -euo pipefail

reg=127.0.0.1:15000
crane auth login "$reg" -u devops -p devopslings >/dev/null 2>&1
cd /work/keys
[ -f cosign.key ] || COSIGN_PASSWORD= cosign generate-key-pair >/dev/null 2>&1

digest=$(crane digest "$reg/shop/cart:1.2.0")
# Offline sandbox: no transparency log to upload to, and the runtime here reads
# cosign's tag-based signature format rather than the newer bundle.
COSIGN_PASSWORD= cosign sign --yes --key cosign.key \
  --use-signing-config=false --tlog-upload=false --new-bundle-format=false \
  "$reg/shop/cart@$digest" >/dev/null 2>&1

cat > /etc/containers/policy.json <<'JSON'
{
  "default": [{ "type": "reject" }],
  "transports": {
    "docker": {
      "127.0.0.1:15000": [{
        "type": "sigstoreSigned",
        "keyPath": "/work/keys/cosign.pub",
        "signedIdentity": { "type": "matchRepository" }
      }]
    }
  }
}
JSON

/work/deploy/deploy.sh "$reg/shop/cart:1.2.0"
