#!/bin/bash
# Bring pg2 up as a streaming hot standby of pg1.
#
# On first start the data directory is empty and is cloned from pg1. After
# that it starts as whatever it already is — still a standby, or a primary if
# it has been promoted. A promoted pg2 is not quietly turned back into a
# replica by a restart.
set -eu
PGDATA=/var/lib/postgresql/data

# ha-reset asks for a fresh clone by leaving this file, e.g. after a lesson
# promoted pg2 and the pair has to be put back.
if [ -f /ha/pg2/reclone ]; then
  echo "pg2: reclone requested, discarding the data directory"
  rm -rf "${PGDATA:?}"/* /ha/pg2/reclone
fi

if [ ! -s "$PGDATA/PG_VERSION" ]; then
  echo "pg2: no data directory yet, cloning pg1"
  until pg_isready -h pg1 -U postgres -d shop >/dev/null 2>&1; do sleep 1; done
  rm -rf "${PGDATA:?}"/*
  # --write-recovery-conf writes standby.signal and primary_conninfo. Without
  # it the clone starts as an independent primary that replicates nothing.
  pg_basebackup --host=pg1 --username=replicator --pgdata="$PGDATA" \
    --wal-method=stream --write-recovery-conf --no-password
  # Names this standby, so pg1 can list it in synchronous_standby_names.
  echo "primary_conninfo = 'host=pg1 user=replicator password=replicate application_name=pg2'" \
    >> "$PGDATA/postgresql.auto.conf"
  chown -R postgres:postgres "$PGDATA"
  chmod 0700 "$PGDATA"
  echo "pg2: base backup complete"
fi

exec docker-entrypoint.sh postgres -c max_connections=60 -c shared_buffers=64MB
