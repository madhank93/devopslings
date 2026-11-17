#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail
cd /root/billing
oct() { awk -F, -v ids=" $* " 'NR > 1 && index(ids, " " $2 " ") {s += $6} END {printf "%.2f", s}' cur-2026-10.csv; }
vols=$(jq -r '.Volumes[] | select(.State == "available") | .VolumeId' describe-volumes.json | xargs)
xaz=$(awk -F, '$4 ~ /DataTransfer-Regional/ && $2 != "" {print $2}' cur-2026-10.csv | sort -u | xargs)
untagged=$(jq -r '.Reservations[].Instances[] | select((.Tags // []) | map(.Key) | index("owner") | not) | .InstanceId' describe-instances.json | xargs)
cat > FINDINGS <<TXT
unattached-volumes: $vols saving=$(oct $vols)
cross-zone-egress: $xaz saving=$(grep Regional cur-2026-10.csv | awk -F, '{s += $6} END {printf "%.2f", s}')
untagged: $untagged saving=$(oct $untagged)
TXT
cat FINDINGS
