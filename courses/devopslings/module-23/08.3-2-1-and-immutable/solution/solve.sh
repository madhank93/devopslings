#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# A second copy on a different machine, in a restic repository on a server
# that only ever appends: the job's credentials can add snapshots, and the
# server refuses every delete and overwrite, whoever asks.
set -euo pipefail
echo "--append-only" > /ha/backupd/options
docker restart devopslings-ha-backupd >/dev/null
until curl -s -o /dev/null --max-time 1 http://backupd:8000/; do sleep 0.5; done

set -a; . /ha/backups/backup.env; set +a
restic cat config >/dev/null 2>&1 || restic init >/dev/null

cat > /ha/backups/backup.sh <<'SH'
#!/bin/bash
# Nightly backup of the shop database: one copy here, one off-site on backupd.
set -euo pipefail
set -a; . /ha/backups/backup.env; set +a
f=/ha/backups/shop-$(date +%s).dump
pg_dump -Fc -f "$f" shop
restic backup --quiet "$f"
echo "backup written: $f, and sent to $RESTIC_REPOSITORY"
SH
/ha/backups/backup.sh
