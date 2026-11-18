---
kind: lesson
title: "the bucket that is public by a route nobody checked"
description: |
  A customer export in the exports bucket can be downloaded by anyone with
  the URL. Removing the object's public ACL is the first fix everybody tries,
  and it is not enough. Make every object private by every route, and keep
  the application reading them.
name: public-bucket
slug: public-bucket
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
      for k in $(aws iam list-access-keys --user-name exports-app --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null || true); do
        aws iam delete-access-key --user-name exports-app --access-key-id "$k" || true
      done
      aws iam delete-user-policy --user-name exports-app --policy-name read-exports 2>/dev/null || true
      aws iam delete-user --user-name exports-app 2>/dev/null || true
      aws s3api delete-public-access-block --bucket exports 2>/dev/null || true
      aws s3 rb s3://exports --force >/dev/null 2>&1 || true
      aws s3control delete-public-access-block --account-id 000000000000 2>/dev/null || true
      rm -rf /root/exports
      install -d /root/exports $S

      aws s3 mb s3://exports >/dev/null
      for m in 2026-08 2026-09 2026-10; do
        { echo "id,name,email"; for i in 1 2 3; do echo "$i,Customer $i,c$i@example.com"; done; } \
          | aws s3 cp - "s3://exports/customers/$m.csv" >/dev/null
      done
      echo "month,orders" | aws s3 cp - s3://exports/reports/summary.csv >/dev/null

      # Three routes to the public: one object's ACL (which one changes per
      # reset), the bucket's ACL, and a bucket policy written for reports/
      # that covers the whole bucket.
      pick=$(printf '2026-08\n2026-09\n2026-10\n' | shuf -n1)
      aws s3api put-object-acl --bucket exports --key "customers/$pick.csv" --acl public-read
      aws s3api put-bucket-acl --bucket exports --acl public-read
      aws s3api put-bucket-policy --bucket exports --policy '{
        "Version": "2012-10-17",
        "Statement": [{
          "Sid": "PublicReports",
          "Effect": "Allow",
          "Principal": "*",
          "Action": "s3:GetObject",
          "Resource": "arn:aws:s3:::exports/*"
        }]
      }'

      # The application: an IAM user whose own policy lets it read the bucket.
      aws iam create-user --user-name exports-app >/dev/null
      aws iam put-user-policy --user-name exports-app --policy-name read-exports --policy-document \
        '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::exports/*"}]}'
      aws iam create-access-key --user-name exports-app --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text > $S/public-bucket.app

      cd /root/exports
      cat > anon <<'SH'
      #!/bin/sh
      # anon KEY: fetches s3://exports/KEY with no credentials at all, as
      # anyone on the internet would. With no KEY, lists the bucket.
      if [ -n "$1" ]; then
        curl -sS -o /dev/null -w "GET exports/$1 anonymously: HTTP %{http_code}\n" "http://floci:4566/exports/$1"
      else
        curl -sS -o /dev/null -w "LIST exports anonymously: HTTP %{http_code}\n" "http://floci:4566/exports?list-type=2"
      fi
      SH
      chmod +x anon
      cat > app-read <<'SH'
      #!/bin/sh
      # app-read KEY: reads s3://exports/KEY as the application, exports-app.
      read -r ak sk < /var/lib/devopslings/public-bucket.app
      AWS_ACCESS_KEY_ID=$ak AWS_SECRET_ACCESS_KEY=$sk aws s3 cp "s3://exports/$1" -
      SH
      chmod +x app-read

      cat > README <<TXT
      Someone found customers/$pick.csv in the exports bucket downloadable by
      anyone with the URL:

        ./anon customers/$pick.csv      HTTP 200, no credentials
        ./app-read customers/$pick.csv  how the application reads it

      Fix it:

        - No object in exports can be read, or listed, without credentials,
          by any route: object ACLs, the bucket ACL, or the bucket policy.
        - S3 Block Public Access is on for the bucket and for the account, all
          four settings, so the next public grant is refused.
        - The application, exports-app, still reads every object.
      TXT
      echo "scenario ready — /root/exports: ./anon customers/$pick.csv, and read the README"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 120
    run: |
      S=/var/lib/devopslings
      if [ ! -s $S/public-bucket.app ]; then
        echo "not yet: the scenario's records are missing — reset the lesson"
        exit 1
      fi
      read -r ak sk < $S/public-bucket.app
      if ! aws s3api head-bucket --bucket exports >/dev/null 2>&1; then
        echo "not yet: the exports bucket is gone. Deleting the data is not making it private;"
        echo "         reset the lesson to get it back"
        exit 1
      fi
      keys=$(aws s3api list-objects-v2 --bucket exports --query 'Contents[].Key' --output text 2>/dev/null | tr '\t' '\n' | grep -v '^None$' || true)
      for want in customers/2026-08.csv customers/2026-09.csv customers/2026-10.csv reports/summary.csv; do
        if ! grep -qx "$want" <<<"$keys"; then
          echo "not yet: $want is gone from exports. The application still needs it; make it"
          echo "         private, do not delete it. Reset the lesson to get it back"
          exit 1
        fi
      done

      bpa_ok() { jq -e '.PublicAccessBlockConfiguration | .BlockPublicAcls and .IgnorePublicAcls and .BlockPublicPolicy and .RestrictPublicBuckets' >/dev/null 2>&1; }
      public_grant() { jq -e '.Grants[]? | select(.Grantee.URI? // "" | test("AllUsers|AuthenticatedUsers"))' >/dev/null 2>&1; }
      policy=$(aws s3api get-bucket-policy --bucket exports --query Policy --output text 2>/dev/null || true)
      policy_public=$(jq -r '[.Statement] | flatten[] | select(.Effect == "Allow")
        | select(.Principal == "*" or ((.Principal.AWS? // "") | tostring | test("^\\*$|\"\\*\""))) | (.Sid // "(no Sid)")' <<<"${policy:-{\}}" 2>/dev/null || true)

      for k in $keys; do
        code=$(curl -sS -o /dev/null -w '%{http_code}' "http://floci:4566/exports/$k" || true)
        if [ "$code" = 200 ]; then
          echo "not yet: exports/$k can still be downloaded without credentials. Routes still open:"
          if aws s3api get-object-acl --bucket exports --key "$k" --output json 2>/dev/null | public_grant; then
            echo "         - the object's own ACL grants AllUsers READ"
          fi
          if [ -n "$policy_public" ]; then
            echo "         - the bucket policy statement $policy_public allows Principal \"*\""
            echo "           s3:GetObject. A bucket policy applies to every object it names,"
            echo "           whatever their ACLs say"
          fi
          if aws s3api get-public-access-block --bucket exports --output json 2>/dev/null | bpa_ok; then
            echo "         Block Public Access is on, and on AWS it would hide these routes. floci does"
            echo "         not enforce it, and the lesson asks for the routes themselves to be closed:"
            echo "         if it is ever turned off to publish something else, they reopen"
          fi
          exit 1
        fi
      done
      code=$(curl -sS -o /dev/null -w '%{http_code}' "http://floci:4566/exports?list-type=2" || true)
      if [ "$code" = 200 ]; then
        echo "not yet: no object can be downloaded anonymously, but the bucket can still be"
        echo "         listed anonymously: its ACL grants AllUsers READ. A listing hands"
        echo "         anyone every key name, and key names here are customer exports"
        exit 1
      fi
      if aws s3api get-bucket-acl --bucket exports --output json 2>/dev/null | public_grant; then
        echo "not yet: the bucket ACL still grants AllUsers or AuthenticatedUsers access"
        exit 1
      fi
      for k in $keys; do
        if aws s3api get-object-acl --bucket exports --key "$k" --output json 2>/dev/null | public_grant; then
          echo "not yet: exports/$k still has a public ACL. Nothing reads it today; the next"
          echo "         change to the bucket policy or Block Public Access would"
          exit 1
        fi
      done
      if [ -n "$policy_public" ]; then
        echo "not yet: the bucket policy statement $policy_public still allows Principal \"*\""
        exit 1
      fi

      for k in $keys; do
        if ! AWS_ACCESS_KEY_ID=$ak AWS_SECRET_ACCESS_KEY=$sk aws s3 cp "s3://exports/$k" - >/dev/null 2>&1; then
          echo "not yet: the application (exports-app) can no longer read exports/$k."
          if grep -q '"Deny"' <<<"${policy:-}"; then
            echo "         The bucket policy has a Deny, and an explicit Deny beats any Allow,"
            echo "         including the application's own"
          fi
          exit 1
        fi
      done

      if ! aws s3api get-public-access-block --bucket exports --output json 2>/dev/null | bpa_ok; then
        echo "not yet: the routes are closed, and nothing stops the next person from opening"
        echo "         one. Turn on all four Block Public Access settings for the bucket"
        echo "         (aws s3api put-public-access-block)"
        exit 1
      fi
      if ! aws s3control get-public-access-block --account-id 000000000000 --output json 2>/dev/null | bpa_ok; then
        echo "not yet: the bucket has Block Public Access, and the account does not. Every"
        echo "         new bucket starts without it, and a bucket-level setting can be turned"
        echo "         off by anyone allowed s3:PutBucketPublicAccessBlock. Set all four at"
        echo "         the account level too (aws s3control put-public-access-block)"
        exit 1
      fi
      echo "PASS — no object in exports is readable or listable anonymously by any route,"
      echo "       Block Public Access is on for the bucket and the account, and exports-app"
      echo "       still reads every object."
---
