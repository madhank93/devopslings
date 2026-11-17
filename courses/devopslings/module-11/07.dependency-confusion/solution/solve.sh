#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
# One index: the internal one, which already mirrors the public packages the
# service uses. pip never asks the public index about anything.
set -euo pipefail

cat > /work/billing/pip.conf <<'CONF'
[global]
index-url = http://127.0.0.1:3141/simple/
trusted-host = 127.0.0.1
CONF

/work/billing/ci/install.sh
