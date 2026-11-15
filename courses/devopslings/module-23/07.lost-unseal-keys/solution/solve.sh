#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The escrowed keys belong to an older cluster, so the sealed data is gone.
# Rebuild: wipe and initialise, re-create the secrets from their sources of
# truth (a new pg1 password; the payment key would be re-issued by the
# gateway), give the app a token, and escrow the new keys where a restart
# cannot take them.
set -euo pipefail
echo "old_secrets_recoverable: no" > /ha/answers/lost-unseal-keys.txt

docker exec devopslings-ha-bao sh -c 'rm -rf /openbao/file/* /openbao/file/.[!.]*'
docker restart devopslings-ha-bao >/dev/null
until [ "$(bao status >/dev/null 2>&1; echo $?)" = 2 ]; do sleep 0.5; done
init=$(bao operator init -key-shares=3 -key-threshold=2 -format=json)
{
  echo "OpenBao unseal keys — escrow copy, made at rebuild ($(date +%F)). Any two unseal it."
  jq -r '.unseal_keys_b64[]' <<<"$init"
} > /ha/bao/escrow/unseal-keys.txt
for i in 0 1; do bao operator unseal "$(jq -r ".unseal_keys_b64[$i]" <<<"$init")" >/dev/null; done
export BAO_TOKEN; BAO_TOKEN=$(jq -r .root_token <<<"$init")

bao secrets enable -path=secret kv-v2 >/dev/null
pw=$(head -c 18 /dev/urandom | base64 | tr -d '/+=')
psql -qX -c "ALTER ROLE shop_app PASSWORD '$pw'"
bao kv put secret/shop/db username=shop_app password="$pw" >/dev/null

bao policy write shop-app - >/dev/null <<'HCL'
path "secret/data/shop/*" {
  capabilities = ["read"]
}
HCL
bao token create -policy=shop-app -orphan -period=768h -field=token > /ha/app/bao-token
