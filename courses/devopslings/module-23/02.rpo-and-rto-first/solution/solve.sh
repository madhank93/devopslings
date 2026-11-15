#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Objectives at the business's limits, then the only family of designs that
# meets both: base backups often enough that WAL replay fits the RTO
# (15 + 25 + 4h <= 60, so h <= 5), and archive_timeout no longer than the RPO.
set -euo pipefail
cat > /ha/answers/rpo-rto.txt <<'TXT'
rpo_minutes: 15
rto_minutes: 60

method: basebackup+wal
full_backup_every_hours: 4
archive_timeout_seconds: 300
TXT
