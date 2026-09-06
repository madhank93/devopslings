#!/bin/bash
# Bring the replica up as a streaming hot standby.
#
# Written out rather than hidden in an image because module 10 asks students to
# reason about replication lag, and lag is much harder to think about if the
# thing producing it is a black box.
#
# Idempotent: on a restart the data directory is already a standby, so the
# basebackup is skipped and Postgres just starts.
set -eu

PGDATA=/var/lib/postgresql/data

if [ ! -s "$PGDATA/PG_VERSION" ]; then
  echo "replica: no data directory yet, cloning the primary"

  # The primary is healthy by the time compose starts this, but healthy means
  # accepting connections — a base backup also needs a wal sender free.
  until pg_isready -h primary -U postgres -d shop >/dev/null 2>&1; do
    sleep 1
  done

  rm -rf "${PGDATA:?}"/*
  # --write-recovery-conf is what makes this a standby rather than a copy: it
  # writes standby.signal and the primary_conninfo to stream from. Without it
  # pg_basebackup still clones ten million rows and the result starts as an
  # independent primary, which looks healthy and replicates nothing.
  #
  # --wal-method=stream keeps WAL flowing during the copy, so a large seed
  # cannot age the backup out from under itself.
  pg_basebackup \
    --host=primary \
    --username=replicator \
    --pgdata="$PGDATA" \
    --wal-method=stream \
    --write-recovery-conf \
    --progress \
    --no-password

  chmod 0700 "$PGDATA"
  echo "replica: base backup complete"
fi

exec docker-entrypoint.sh postgres
