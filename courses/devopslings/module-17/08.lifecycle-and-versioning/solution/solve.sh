#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail
B=ledgers
# Versions newest first: [0] is the header-only file, [1] the last complete ledger.
v=$(aws s3api list-object-versions --bucket $B --prefix settlement/ledger.csv --query 'Versions[1].VersionId' --output text)
aws s3api copy-object --bucket $B --key settlement/ledger.csv --copy-source "$B/settlement/ledger.csv?versionId=$v" >/dev/null
aws s3api put-bucket-lifecycle-configuration --bucket $B --lifecycle-configuration '{
  "Rules": [{"ID": "old-versions", "Status": "Enabled", "Filter": {},
    "NoncurrentVersionExpiration": {"NoncurrentDays": 30},
    "Expiration": {"ExpiredObjectDeleteMarker": true}}]}'
sed -i 's/^rm_kept=.*/rm_kept=kept-as-noncurrent/' /root/ledgers/ANSWER
