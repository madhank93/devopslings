#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail
for k in $(aws s3api list-objects-v2 --bucket exports --query 'Contents[].Key' --output text); do
  aws s3api put-object-acl --bucket exports --key "$k" --acl private
done
aws s3api put-bucket-acl --bucket exports --acl private
aws s3api delete-bucket-policy --bucket exports
ALL=BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-public-access-block --bucket exports --public-access-block-configuration "$ALL"
aws s3control put-public-access-block --account-id 000000000000 --public-access-block-configuration "$ALL"
cd /root/exports && ./anon customers/2026-10.csv && ./anon && ./app-read customers/2026-10.csv
