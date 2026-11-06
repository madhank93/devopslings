#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# BackupStale stays for backups that stop completing. BackupMetricsMissing
# fires when there is no timestamp to compare at all, and its for: rides out
# the few seconds a deploy takes.
set -euo pipefail
cat > /obs/prometheus/rules/backup.yml <<'YML'
groups:
  - name: backup
    rules:
      - alert: BackupStale
        expr: time() - backup_last_success_timestamp_seconds{job="backup"} > 30
        for: 10s
        labels:
          severity: critical
        annotations:
          summary: no backup has completed in 30 seconds

      - alert: BackupMetricsMissing
        expr: absent(backup_last_success_timestamp_seconds{job="backup"})
        for: 45s
        labels:
          severity: critical
        annotations:
          summary: nothing reports when the last backup completed, so BackupStale cannot fire
YML
obs-reload
