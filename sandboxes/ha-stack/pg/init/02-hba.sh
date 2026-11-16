#!/bin/bash
# Replication and app connections from the back network. Passwords are
# required; this is a sandbox, not a template.
set -eu
cat >> "$PGDATA/pg_hba.conf" <<'HBA'
host replication replicator 172.29.23.0/24 scram-sha-256
host all         all        172.29.23.0/24 scram-sha-256
HBA
