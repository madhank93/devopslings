#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail
aws iam put-user-policy --user-name share-bot --policy-name share --policy-document \
  '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::invoices/2026-10/acme-*"}]}'
aws --profile share s3 presign s3://invoices/2026-10/acme-4471.pdf --expires-in 900 > /root/share/LINK
curl -sS -o /dev/null -w '%{http_code}\n' "$(cat /root/share/LINK)"
