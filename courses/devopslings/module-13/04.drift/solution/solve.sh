#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail
cd /root/infra

# The code is right; apply puts the deleted container back.
tofu apply -auto-approve -input=false

cat > ci/drift-check.sh <<'SH'
#!/bin/sh
# Exit 0: no drift. 2: drift. Anything else: the check could not run.
# Read-only: plans, never applies.
tofu init -input=false >/dev/null || exit 1
exec tofu plan -input=false -lock=false -detailed-exitcode
SH
chmod +x ci/drift-check.sh

cat > .forgejo/workflows/drift.yml <<'YML'
on:
  schedule:
    - cron: "*/30 * * * *"
jobs:
  drift:
    runs-on: iac
    steps:
      - uses: actions/checkout@v4
      - run: ci/drift-check.sh
YML
