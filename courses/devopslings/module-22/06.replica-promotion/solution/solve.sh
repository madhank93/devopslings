#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Synchronous replication on pg1, so a commit is confirmed only once pg2 has
# it; and a failover that promotes pg2 and points the app at it.
set -euo pipefail
psql -h pg1 -qc "ALTER SYSTEM SET synchronous_standby_names = 'pg2'" -c "SELECT pg_reload_conf()"

cat > /ha/failover.sh <<'SH'
#!/bin/bash
# Run from ops once pg1 is dead: promote pg2, then move the app onto it.
set -eu
psql -h pg2 -qtAc "SELECT pg_promote(wait => true)"
sed -i 's/host=pg1/host=pg2/' /ha/app.env
SH
chmod +x /ha/failover.sh
