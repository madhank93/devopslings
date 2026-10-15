#!/bin/sh
# Start OpenBao, then initialise it once and unseal it on every start.
#
# The unseal key lives in the same volume as the encrypted storage so the
# sandbox comes back unsealed after a restart. That defeats the point of
# sealing, and is the one thing here never to copy into production.
#
# The root token has a fixed id, devopslings-root, for the same reason the
# forge has a fixed password: lessons and students need to be able to log in.
set -eu

export BAO_ADDR=http://127.0.0.1:8200
d=/openbao/file
mkdir -p "$d/storage"

bao server -config=/init/openbao.hcl &

# `bao status` exits 1 while the server is unreachable, 2 while it is sealed.
until bao status >/dev/null 2>&1; [ $? -ne 1 ]; do sleep 0.3; done

if [ ! -s "$d/unseal-key" ]; then
  out=$(bao operator init -key-shares=1 -key-threshold=1)
  printf '%s\n' "$out" | sed -n 's/^Unseal Key 1: //p' > "$d/unseal-key"
  root=$(printf '%s\n' "$out" | sed -n 's/^Initial Root Token: //p')
  bao operator unseal "$(cat "$d/unseal-key")" >/dev/null
  BAO_TOKEN=$root bao token create -id=devopslings-root -policy=root -orphan >/dev/null
  BAO_TOKEN=$root bao secrets enable -path=secret kv-v2 >/dev/null
  BAO_TOKEN=$root bao token revoke -self >/dev/null
  echo "openbao initialised"
else
  bao operator unseal "$(cat "$d/unseal-key")" >/dev/null
fi
echo "openbao unsealed — http://localhost:8200  (token: devopslings-root)"

wait
