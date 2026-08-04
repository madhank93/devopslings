#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

cat > /usr/local/bin/provision-tenant <<'SH'
#!/bin/bash
set -euo pipefail

# `set -e` is suspended in any context whose purpose is to TEST a status. That
# is not a bug; a shell that aborted inside `if` conditions would make `if`
# useless. The fix in every case is the same: stop using a testing context for
# something that is not a test.

# 1. Was: `if tenant-step create-db; then ...`
#    The status was being consumed by the `if`. Run it plainly and let `set -e`
#    see the failure.
tenant-step create-db
echo "provision: database ready"

# 2. Was: `tenant-step create-schema && echo ...`
#    The left side of && is a testing context too.
tenant-step create-schema
echo "provision: schema ready"

# 3. Was: `local creds=$(tenant-step create-user)`
#    `local` is itself a command, and it succeeds. Its status is what the shell
#    sees, so the failure inside the substitution is discarded. Note a plain
#    `creds=$(...)` does NOT have this problem — the status propagates. It is
#    `local`, `export` and `declare` that swallow it, which makes this the
#    hardest of the four to spot: adding `local` for good hygiene is what
#    introduces the bug.
#
#    Declare first, assign second.
make_creds() {
  local creds
  creds=$(tenant-step create-user)
  echo "provision: creds=${creds:-none}"
}
make_creds

# 4. Was: `if seed; then ...`
#    Suspension applies to the whole call and everything it invokes, however
#    deep. Call the function normally.
seed() {
  tenant-step seed-data
  echo "provision: seeded"
}
seed
echo "provision: seed step returned"

echo "provision: tenant is ready"
SH
chmod 0755 /usr/local/bin/provision-tenant
