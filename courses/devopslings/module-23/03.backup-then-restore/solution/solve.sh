#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The backup role could not read refunds, so pg_dump died at its first lock,
# and gzip's exit status hid it. pg_read_all_data covers tables created later;
# pipefail makes the job fail when any stage of the pipe does.
set -euo pipefail
psql -qX -c "GRANT pg_read_all_data TO backup"
cat > /ha/backups/backup.sh <<'SH'
#!/bin/bash
# Nightly logical backup of the shop database, as the read-only backup role.
# Writes /ha/backups/shop.sql.gz, a plain SQL dump, gzipped.
set -euo pipefail
out=/ha/backups/shop.sql.gz
PGUSER=backup PGPASSWORD=backup pg_dump --host=pg1 --dbname=shop | gzip > "$out"
echo "backup written: $out ($(stat -c %s "$out") bytes)"
SH
