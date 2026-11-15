#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# One check per method, each asking whether the method could restore data
# today: the dump has content, the snapshot is fresh, the archiver's last
# attempt succeeded, pg2 is replaying, and the offsite repository has a
# recent snapshot.
set -euo pipefail
cat > /ha/dr/verify-backups.sh <<'SH'
#!/bin/bash
B=/ha/backups
rc=0
fail() { echo "FAIL $1: $2"; rc=1; }

newest=$(ls -1 "$B"/dumps/shop-*.sql.gz 2>/dev/null | sort | tail -1)
if [ -z "$newest" ]; then fail dumps "no dump files"
elif [ -z "$(find "$newest" -mmin -1500)" ]; then fail dumps "newest dump $newest is over a day old"
elif ! gunzip -c "$newest" 2>/dev/null | grep -q 'PostgreSQL database dump complete'; then
  fail dumps "newest dump $newest is not a complete pg_dump"
fi

if [ -z "$(find "$B/snapshots" -mindepth 1 -maxdepth 1 -type d -mmin -1440 2>/dev/null)" ]; then
  fail snapshots "no snapshot in the last 24 hours"
fi

state=$(psql -h pg1 -tAX -c "SELECT current_setting('archive_mode') || ' ' ||
  CASE WHEN last_failed_time > coalesce(last_archived_time, '-infinity') THEN 'failing' ELSE 'ok' END
  FROM pg_stat_archiver" 2>/dev/null)
case $state in
  "on ok") ;;
  "") fail wal-archive "cannot read pg_stat_archiver on pg1" ;;
  *) fail wal-archive "archive_mode/archiver: $state" ;;
esac

lag=$(psql -h pg1 -tAX -c "SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)
  FROM pg_stat_replication WHERE application_name = 'pg2' AND state = 'streaming'" 2>/dev/null)
paused=$(psql -h pg2 -tAX -c "SELECT pg_is_wal_replay_paused()" 2>/dev/null)
if [ -z "$lag" ]; then fail replica "pg2 is not streaming from pg1"
elif [ "$paused" != f ] || [ "${lag%.*}" -gt 1048576 ]; then
  fail replica "pg2 is ${lag%.*} bytes behind pg1 (replay paused: ${paused:-unknown})"
fi

recent=$( (set -a; . "$B/offsite.env"; set +a; restic snapshots --json 2>/dev/null) \
  | jq -r '[.[] | select(.time > (now - 93600 | todate))] | length' 2>/dev/null)
[ "${recent:-0}" -gt 0 ] || fail offsite "no snapshot in the offsite repository from the last 26 hours"

exit $rc
SH
chmod +x /ha/dr/verify-backups.sh
