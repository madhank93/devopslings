#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
# Pin the base to the manifest digest yesterday's green build resolved `2` to.
set -euo pipefail

cd /work/shop-web
digest=$(grep -m1 -o 'upstream/runtime:2@sha256:[0-9a-f]*' ci/builds/1041.log | cut -d@ -f2)
sed -i "s|^FROM 127.0.0.1:15000/upstream/runtime:2\$|FROM 127.0.0.1:15000/upstream/runtime@$digest|" Dockerfile
grep -q "@$digest" Dockerfile
docker build -q --pull -t devopslings-m11/shop-web:local . >/dev/null
docker rmi devopslings-m11/shop-web:local >/dev/null
