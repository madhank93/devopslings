"""backup — the backup job's exporter. Metrics on :9101.

A backup completes every 10 seconds. While /obs/run/backup.fault holds an epoch
second, the job has stopped completing and that is its last success.
"""
import time

from prometheus_client import Gauge, start_http_server

LAST = Gauge("backup_last_success_timestamp_seconds", "When the last backup completed, as a Unix time.")

start_http_server(9101)
last = time.time()
while True:
    try:
        last = float(open("/obs/run/backup.fault").read().strip())
    except (OSError, ValueError):
        if time.time() - last >= 10:
            last = time.time()
    LAST.set(last)
    time.sleep(1)
