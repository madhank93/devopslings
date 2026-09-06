#!/bin/bash
# Let the replica in. initdb writes pg_hba.conf before this runs, so the
# replication line is appended rather than templated — and it is scoped to the
# compose network's subnet rather than "all", so a lesson cannot accidentally
# demonstrate that anything on the host can stream the database.
set -eu

cat >> "$PGDATA/pg_hba.conf" <<'HBA'

# db-stack: streaming replication from the replica container.
host    replication     replicator      all                     scram-sha-256
HBA

echo "db-stack: replication entry added to pg_hba.conf"
