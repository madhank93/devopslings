#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail
cd /root/reports

# Inside Lambda, boto3 picks up the execution role's session credentials from
# the environment the runtime sets; nothing needs to be passed in.
rm -f config.py
cat > handler.py <<'PY'
"""reports: counts the rows in today's summary, and says who it ran as."""
import boto3

s3 = boto3.client("s3")
sts = boto3.client("sts")


def handler(event, context):
    body = s3.get_object(Bucket="reports-data", Key="daily/summary.csv")["Body"].read()
    rows = len(body.decode().splitlines()) - 1
    return {"rows": rows, "ran_as": sts.get_caller_identity()["Arn"]}
PY
sed -i -e '/^ENV=/d' -e 's/ --environment "\$ENV"//' deploy.sh
sed -i 's/--role "\$ROLE" >\/dev\/null/--role "$ROLE" --environment "Variables={}" >\/dev\/null/' deploy.sh

aws iam put-role-policy --role-name reports --policy-name read-summary --policy-document \
  '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::reports-data/daily/summary.csv"}]}'
./deploy.sh
for k in $(aws iam list-access-keys --user-name reports-bot --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
  aws iam delete-access-key --user-name reports-bot --access-key-id "$k"
done
./invoke
