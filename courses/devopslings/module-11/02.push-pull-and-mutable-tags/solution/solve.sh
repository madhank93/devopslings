#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
# Resolve the release to its digest once, and deploy that digest.
set -euo pipefail

reg=127.0.0.1:15000
crane auth login "$reg" -u devops -p devopslings >/dev/null 2>&1
digest=$(crane digest "$reg/shop/web:1.4.0")

sed -i "s#image: .*#image: $reg/shop/web@$digest#" /work/deploy/compose.yaml
/work/deploy/deploy.sh
