#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail
cd /root/deploy
cat > trust.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::111111111111:role/ci" },
      "Action": "sts:AssumeRole"
    }
  ]
}
JSON
aws iam update-assume-role-policy --role-name deploy --policy-document file://trust.json
sed -i -e 's/^who_can_assume=.*/who_can_assume=trust/' -e 's/^what_it_can_do=.*/what_it_can_do=permission/' ANSWER
./become ci
