#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Find the DELETE's transaction in the archived WAL, recover a copy of the
# base backup to just before it on the side, and copy the deleted rows back
# into pg1. pg1 itself is never rewound, so orders placed since survive.
set -euo pipefail
wal=/ha/archive/wal
# The transaction that wrote the most heap DELETE records is the cleanup.
xid=$(for f in $(ls "$wal" | grep -E '^[0-9A-F]{24}$'); do pg_waldump -p "$wal" "$f" 2>/dev/null || true; done \
  | awk '/desc: DELETE/ { for (i = 1; i <= NF; i++) if ($i == "tx:") { sub(",", "", $(i+1)); print $(i+1) } }' \
  | sort | uniq -c | sort -rn | awk 'NR == 1 { print $2 }')
echo "the DELETE was transaction $xid"

d=/var/lib/pitr
rm -rf "$d"
mkdir -p "$d"
tar -xzf /ha/archive/base/base.tar.gz -C "$d"
# The copy inherits pg1's archive settings; it must not write into pg1's archive.
cat >> "$d/postgresql.auto.conf" <<CONF
archive_mode = off
restore_command = 'cp $wal/%f %p'
recovery_target_xid = '$xid'
recovery_target_inclusive = off
recovery_target_action = promote
port = 5434
listen_addresses = 'localhost'
CONF
touch "$d/recovery.signal"
chown -R postgres:postgres "$d"
chmod 700 "$d"
gosu postgres pg_ctl -D "$d" -l "$d/log" -w -t 120 start >/dev/null

psql -X -h localhost -p 5434 -d shop -c "\copy (SELECT * FROM orders) TO '/root/deleted.csv' CSV"
psql -X -h pg1 -d shop -v ON_ERROR_STOP=1 <<'SQL'
CREATE TEMP TABLE restored (LIKE orders);
\copy restored FROM '/root/deleted.csv' CSV
INSERT INTO orders SELECT * FROM restored ON CONFLICT (id) DO NOTHING;
SQL
gosu postgres pg_ctl -D "$d" -m fast stop >/dev/null
rm -rf "$d" /root/deleted.csv
