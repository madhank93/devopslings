---
kind: lesson
title: "one file for one customer, for fifteen minutes"
description: |
  A customer needs one invoice from a private bucket. Opening the bucket for
  an afternoon is the first idea. Give them a presigned link instead: one
  object, signed by an identity that can read little else, expiring when you
  said it would.
name: presigned-not-public
slug: presigned-not-public
createdAt: "2026-11-14"

sandbox:
  stack: iac-stack
  service: ws

tasks:
  init_scenario:
    init: true
    timeout_seconds: 120
    run: |
      S=/var/lib/devopslings
      for k in $(aws iam list-access-keys --user-name share-bot --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null || true); do
        aws iam delete-access-key --user-name share-bot --access-key-id "$k" || true
      done
      for p in $(aws iam list-user-policies --user-name share-bot --query 'PolicyNames[]' --output text 2>/dev/null || true); do
        aws iam delete-user-policy --user-name share-bot --policy-name "$p" || true
      done
      for p in $(aws iam list-attached-user-policies --user-name share-bot --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || true); do
        aws iam detach-user-policy --user-name share-bot --policy-arn "$p" || true
      done
      aws iam delete-user --user-name share-bot 2>/dev/null || true
      aws s3api delete-public-access-block --bucket invoices 2>/dev/null || true
      aws s3 rb s3://invoices --force >/dev/null 2>&1 || true
      rm -rf /root/share /root/.aws/credentials
      install -d /root/share /root/.aws $S

      aws s3 mb s3://invoices >/dev/null
      printf '%%PDF-1.4 invoice 4471 for Acme, %s\n' "$RANDOM$RANDOM" > /tmp/acme.pdf
      aws s3 cp /tmp/acme.pdf s3://invoices/2026-10/acme-4471.pdf >/dev/null
      sha256sum /tmp/acme.pdf | cut -d' ' -f1 > $S/presigned.sha
      rm -f /tmp/acme.pdf
      echo "%PDF-1.4 invoice 4390" | aws s3 cp - s3://invoices/2026-09/acme-4390.pdf >/dev/null
      echo "%PDF-1.4 invoice 4472" | aws s3 cp - s3://invoices/2026-10/globex-4472.pdf >/dev/null
      echo "employee,salary" | aws s3 cp - s3://invoices/payroll/2026-10.csv >/dev/null

      # share-bot signs customer links. Its policy still points at last month.
      aws iam create-user --user-name share-bot >/dev/null
      aws iam put-user-policy --user-name share-bot --policy-name share --policy-document \
        '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::invoices/2026-09/*"}]}'
      aws iam create-access-key --user-name share-bot --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text > $S/presigned.share
      read -r ak sk < $S/presigned.share
      printf '[share]\naws_access_key_id = %s\naws_secret_access_key = %s\n' "$ak" "$sk" > /root/.aws/credentials
      chmod 600 /root/.aws/credentials
      # The profile's endpoint: the AWS CLI reads it from the shared config file.
      sed -i '/^\[profile share\]/,/^$/d' /etc/aws/config
      printf '\n[profile share]\nregion = us-east-1\nendpoint_url = http://floci:4566\n\n' >> /etc/aws/config

      cat > /root/share/README <<'TXT'
      Acme needs one file, s3://invoices/2026-10/acme-4471.pdf, and has no AWS
      account. The bucket is private and must stay private: it also holds other
      customers' invoices and payroll.

      Links to customers are signed by share-bot, an IAM user whose key is the
      "share" profile (aws --profile share ...). Its policy has not been
      updated since September.

      Fix it:

        - Write a link for that one file into /root/share/LINK. Acme opens it
          with no credentials. It is signed by share-bot and expires 15
          minutes (900 seconds) after you make it.
        - share-bot can read what it needs to sign that link, and not payroll.
        - Nothing in the bucket is public, not even for a minute.

        curl -s -o /dev/null -w '%{http_code}\n' "$(cat /root/share/LINK)"
      TXT
      echo "scenario ready — read /root/share/README"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 120
    run: |
      S=/var/lib/devopslings
      if [ ! -s $S/presigned.share ] || [ ! -s $S/presigned.sha ]; then
        echo "not yet: the scenario's records are missing — reset the lesson"
        exit 1
      fi
      read -r ak sk < $S/presigned.share
      want_sha=$(cat $S/presigned.sha)
      OBJ=2026-10/acme-4471.pdf
      code() { curl -sS -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || echo 000; }

      if ! aws s3api head-object --bucket invoices --key $OBJ >/dev/null 2>&1; then
        echo "not yet: s3://invoices/$OBJ is gone — reset the lesson to get it back"
        exit 1
      fi
      for k in $OBJ payroll/2026-10.csv; do
        if [ "$(code "http://floci:4566/invoices/$k")" = 200 ]; then
          echo "not yet: invoices/$k can be downloaded with no credentials at all, so anyone"
          echo "         who has or guesses its URL can read it, not just Acme. Remove the public"
          echo "         grant (bucket policy, bucket ACL or object ACL); a presigned link needs none"
          exit 1
        fi
      done
      if [ "$(code "http://floci:4566/invoices?list-type=2")" = 200 ]; then
        echo "not yet: the invoices bucket can be listed with no credentials, which hands out"
        echo "         every customer's file name. Remove the public grant on the bucket ACL"
        exit 1
      fi
      pol=$(aws s3api get-bucket-policy --bucket invoices --query Policy --output text 2>/dev/null || true)
      if [ -n "$pol" ] && jq -e '[.Statement] | flatten[] | select(.Effect == "Allow" and (.Principal == "*" or .Principal.AWS? == "*"))' <<<"$pol" >/dev/null 2>&1; then
        echo "not yet: the bucket policy still allows Principal \"*\". Remove it"
        exit 1
      fi

      if [ ! -s /root/share/LINK ]; then
        echo "not yet: /root/share/LINK is missing or empty"
        exit 1
      fi
      link=$(grep -m1 -oE 'https?://[^[:space:]"]+' /root/share/LINK || true)
      if [ -z "$link" ]; then
        echo "not yet: /root/share/LINK has no URL in it"
        exit 1
      fi
      q() { grep -oE "[?&]$1=[^&]*" <<<"$link" | head -1 | cut -d= -f2- || true; }
      path=$(sed -E 's#^https?://[^/]+##; s#\?.*##' <<<"$link")
      if [ "$path" != "/invoices/$OBJ" ]; then
        echo "not yet: the link is for $path, not /invoices/$OBJ"
        exit 1
      fi
      cred=$(q X-Amz-Credential | sed 's/%2F/\//g' | cut -d/ -f1)
      if [ -z "$cred" ]; then
        echo "not yet: the link is not presigned: it carries no X-Amz-Credential. Acme has no"
        echo "         credentials, so the link has to carry a signature (aws s3 presign)"
        exit 1
      fi
      if [ "$cred" != "$ak" ]; then
        if [ "$cred" = test ]; then
          echo "not yet: the link is signed with the account root key. A presigned link carries"
          echo "         its signer's authority: anyone who gets it acts as that signer for that"
          echo "         request. Sign with share-bot: aws --profile share s3 presign ..."
        else
          echo "not yet: the link is signed by key $cred, not share-bot's ($ak)."
          echo "         Sign with the share profile"
        fi
        exit 1
      fi
      exp=$(q X-Amz-Expires)
      if [ "$exp" != 900 ]; then
        echo "not yet: the link is valid for ${exp:-?} seconds; the README says 15 minutes, 900."
        [ "$exp" = 3600 ] && echo "         3600 is aws s3 presign's default; --expires-in sets it"
        exit 1
      fi
      c=$(code "$link")
      if [ "$c" != 200 ]; then
        signed=$(q X-Amz-Date)
        age=$(( $(date -u +%s) - $(date -u -d "$(sed -E 's/(....)(..)(..)T(..)(..)(..)Z/\1-\2-\3 \4:\5:\6/' <<<"$signed")" +%s 2>/dev/null || date -u +%s) ))
        if [ "$age" -gt 900 ]; then
          echo "not yet: the link expired: it was signed ${age}s ago and lasts 900s. That part"
          echo "         works. Sign a fresh one, and write it to LINK"
        elif ! AWS_ACCESS_KEY_ID=$ak AWS_SECRET_ACCESS_KEY=$sk aws s3api head-object --bucket invoices --key $OBJ >/dev/null 2>&1; then
          echo "not yet: opening the link gives HTTP $c. Signing works offline and always"
          echo "         succeeds; the permission is checked when the link is used. share-bot"
          echo "         itself is not allowed to read $OBJ, so neither is its link"
        else
          echo "not yet: opening the link gives HTTP $c"
        fi
        exit 1
      fi
      got=$(curl -sS "$link" | sha256sum | cut -d' ' -f1)
      if [ "$got" != "$want_sha" ]; then
        echo "not yet: the link works, and what it returns is not the invoice that was in the"
        echo "         bucket. Leave the object as it was"
        exit 1
      fi
      tampered=$(sed 's/X-Amz-Expires=900/X-Amz-Expires=604800/' <<<"$link")
      if [ "$(code "$tampered")" = 200 ]; then
        echo "not yet: the link still works with its expiry edited to 7 days. That should be"
        echo "         impossible, since the expiry is part of what is signed"
        exit 1
      fi

      if AWS_ACCESS_KEY_ID=$ak AWS_SECRET_ACCESS_KEY=$sk aws s3api head-object --bucket invoices --key payroll/2026-10.csv >/dev/null 2>&1; then
        echo "not yet: the link is right, and share-bot can also read payroll/2026-10.csv. Anyone"
        echo "         holding share-bot's key, or the tool that signs with it, can sign a link"
        echo "         to payroll. Scope its policy to the invoices it shares"
        exit 1
      fi
      if AWS_ACCESS_KEY_ID=$ak AWS_SECRET_ACCESS_KEY=$sk aws s3api list-objects-v2 --bucket invoices --max-keys 1 >/dev/null 2>&1; then
        echo "not yet: the link is right, and share-bot can also list the bucket, which names"
        echo "         every customer's invoice. Signing a link to one known key needs no listing"
        exit 1
      fi

      # An expired link must fail: sign one for two seconds and use it late.
      short=$(AWS_ACCESS_KEY_ID=$ak AWS_SECRET_ACCESS_KEY=$sk aws s3 presign "s3://invoices/$OBJ" --expires-in 2)
      sleep 4
      if [ "$(code "$short")" = 200 ]; then
        echo "not yet: a share-bot link signed to last 2 seconds still worked after 4"
        exit 1
      fi
      echo "PASS — Acme's link opens the invoice with no credentials, is signed by share-bot,"
      echo "       lasts 900s and cannot be extended; an expired link fails, the bucket is"
      echo "       private, and share-bot cannot read payroll."
---
