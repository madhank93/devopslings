#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Time the documented drill, then the same restore in its two sections, and
# rewrite the runbook's promise with the measured number and the size it was
# measured at.
set -euo pipefail
trap 'scratchdb stop >/dev/null 2>&1 || true' EXIT
now() { python3 -c 'import time; print(time.monotonic())'; }
secs() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", b - a }'; }

s=$(now); /ha/dr/restore.sh >/dev/null; e=$(now)
total=$(secs "$s" "$e")

scratchdb fresh >/dev/null
s=$(now)
pg_restore -O -x -h localhost -p 5433 -d postgres --section=pre-data --section=data /ha/backups/shop.dump
m=$(now)
pg_restore -O -x -h localhost -p 5433 -d postgres --section=post-data /ha/backups/shop.dump
e=$(now)

cat > /ha/answers/restore-drill.txt <<TXT
measured_total_seconds: $total
data_seconds: $(secs "$s" "$m")
indexes_seconds: $(secs "$m" "$e")
TXT
rows=$(psql -tAX -c "SELECT count(*) FROM events")
# Quote a little over the measurement: the next restore will not be faster.
promise=$(awk -v t="$total" 'BEGIN { printf "%d", t * 1.5 + 1 }')
sed -i -e "s/^\(  restore_seconds: *\).*/\1$promise/" \
       -e "s/^\(  measured_rows: *\)[0-9]*/\1$rows/" \
       -e "s/^\(  last_drill: *\).*/\1$(date +%F)/" /ha/dr/runbook.txt
cat /ha/answers/restore-drill.txt /ha/dr/runbook.txt
