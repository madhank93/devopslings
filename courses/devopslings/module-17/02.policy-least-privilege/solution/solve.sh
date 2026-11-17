#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail
cd /root/ingest

# One statement per resource: ListBucket acts on the bucket, the object
# actions on the prefixes the handler touches.
cat > policy.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::uploads"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::uploads/incoming/*"
    },
    {
      "Effect": "Allow",
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::uploads/processed/*"
    }
  ]
}
JSON
aws iam put-role-policy --role-name ingest --policy-name ingest --policy-document file://policy.json
./invoke
