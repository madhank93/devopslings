#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Take the backup, then read it: a table's rows are in the dump only if a
# COPY block for it follows. CREATE TABLE alone restores an empty table.
set -euo pipefail
/ha/backups/nightly.sh
{
  echo "# answered from the COPY blocks in /ha/backups/shop.sql"
  for t in customers orders refunds; do
    if grep -q "^COPY public\.$t " /ha/backups/shop.sql; then echo "$t: yes"; else echo "$t: no"; fi
  done
} > /ha/answers/take-a-backup.txt
