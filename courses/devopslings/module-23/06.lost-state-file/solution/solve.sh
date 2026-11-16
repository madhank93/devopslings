#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Re-adopt the existing objects with import blocks, apply (imports plus any
# in-place drift, nothing created), then check the plan is empty.
set -euo pipefail
cd /ha/infra
cat > imports.tf <<'TF'
# Adopts objects that already exist on pg1 into the state. Safe to keep:
# once an address is in the state, its import block does nothing.
import {
  to = postgresql_role.reporting
  id = "reporting"
}

import {
  to = postgresql_role.analyst
  id = "analyst"
}

import {
  to = postgresql_database.analytics
  id = "analytics"
}

import {
  to = postgresql_schema.marts
  id = "analytics.marts"
}
TF
tofu plan -input=false -no-color | grep -E '^Plan:'
tofu apply -auto-approve -input=false -no-color | grep -E '^Apply'
tofu plan -detailed-exitcode -input=false -no-color >/dev/null
