#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Expand only: v2's columns are added, nothing v1 uses is renamed or loses
# its default. created_at is computed from placed_at, so it is right on rows
# either version writes. The rollback is a traffic switch in the shared
# config, which both load balancers reload within a second.
set -euo pipefail
cat > /ha/sre/migrations/002-v2.sql <<'SQL'
-- Shipped with v2. Additive only: v1 must keep running on this schema.
ALTER TABLE bg.orders ADD COLUMN currency text NOT NULL DEFAULT 'EUR';
ALTER TABLE bg.orders ADD COLUMN created_at timestamptz GENERATED ALWAYS AS (placed_at) STORED;
SQL
cat > /ha/sre/rollback <<'SH'
#!/bin/bash
# Send www back to blue (v1), then wait until both load balancers do.
set -eu
sed -i -E 's/^([[:space:]]*default_backend[[:space:]]+)green/\1blue/' /ha/haproxy.cfg
for lb in lb1 lb2; do
  for _ in $(seq 40); do
    curl -s -o /dev/null -D - --max-time 2 "http://$lb/checkout" | grep -qi '^x-build: v1' && break
    sleep 0.25
  done
done
echo "www -> blue"
SH
chmod +x /ha/sre/rollback
