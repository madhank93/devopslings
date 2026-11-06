#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail
cd /root/shared

# The orphans hold nothing; let the next deploy recreate them from code.
docker rm -f web worker >/dev/null

# Lock with an object next to the state, and wait for it rather than fail.
sed -i 's/^\(    skip_region_validation      = true\)$/\1\n    use_lockfile                = true/' versions.tf
sed -i 's/^tofu apply -auto-approve -input=false$/tofu apply -auto-approve -input=false -lock-timeout=5m/' deploy.sh

tofu init -input=false -reconfigure >/dev/null
./deploy.sh
