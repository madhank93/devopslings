---
kind: lesson
title: "the access key in the repository"
description: |
  reports, a Lambda function, reads S3 with an access key that is committed
  to its repository and copied into its environment. Run it on its execution
  role instead, and make sure the leaked key can never be used again.
name: identity-not-keys
slug: identity-not-keys
createdAt: "2026-11-14"

sandbox:
  stack: iac-stack
  service: ws

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      F=http://floci:4566/2015-03-31/functions
      load-lambda-runtime
      curl -sS -o /dev/null -X DELETE "$F/reports" || true
      for k in $(aws iam list-access-keys --user-name reports-bot --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null || true); do
        aws iam delete-access-key --user-name reports-bot --access-key-id "$k" || true
      done
      aws iam delete-user-policy --user-name reports-bot --policy-name read-reports 2>/dev/null || true
      aws iam delete-user --user-name reports-bot 2>/dev/null || true
      for p in $(aws iam list-role-policies --role-name reports --query 'PolicyNames[]' --output text 2>/dev/null || true); do
        aws iam delete-role-policy --role-name reports --policy-name "$p" || true
      done
      for p in $(aws iam list-attached-role-policies --role-name reports --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || true); do
        aws iam detach-role-policy --role-name reports --policy-arn "$p" || true
      done
      aws iam delete-role --role-name reports 2>/dev/null || true
      aws s3 rb s3://reports-data --force >/dev/null 2>&1 || true
      rm -rf /root/reports
      install -d /root/reports /var/lib/devopslings

      # The data: one header line and a row count that changes per reset.
      rows=$(( (RANDOM % 50) + 40 ))
      aws s3 mb s3://reports-data >/dev/null
      { echo "date,region,orders"; for i in $(seq 1 "$rows"); do echo "2026-11-13,r$i,$((RANDOM % 900))"; done; } \
        | aws s3 cp - s3://reports-data/daily/summary.csv >/dev/null
      echo "$rows" > /var/lib/devopslings/identity-not-keys.rows

      aws iam create-user --user-name reports-bot >/dev/null
      aws iam put-user-policy --user-name reports-bot --policy-name read-reports --policy-document \
        '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::reports-data/daily/*"}]}'
      key=$(aws iam create-access-key --user-name reports-bot)
      ak=$(jq -r .AccessKey.AccessKeyId <<<"$key")
      sk=$(jq -r .AccessKey.SecretAccessKey <<<"$key")
      printf '%s %s\n' "$ak" "$sk" > /var/lib/devopslings/identity-not-keys.leaked

      # The execution role exists, and is allowed nothing yet.
      aws iam create-role --role-name reports --assume-role-policy-document \
        '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null

      cd /root/reports
      cat > config.py <<PY
      """Credentials for the reports function."""
      import os

      ACCESS_KEY_ID = os.environ.get("REPORTS_KEY_ID", "$ak")
      SECRET_ACCESS_KEY = os.environ.get("REPORTS_SECRET", "$sk")
      PY

      cat > handler.py <<'PY'
      """reports: counts the rows in today's summary, and says who it ran as."""
      import boto3

      from config import ACCESS_KEY_ID, SECRET_ACCESS_KEY

      session = boto3.Session(
          aws_access_key_id=ACCESS_KEY_ID,
          aws_secret_access_key=SECRET_ACCESS_KEY,
      )
      s3 = session.client("s3")
      sts = session.client("sts")


      def handler(event, context):
          body = s3.get_object(Bucket="reports-data", Key="daily/summary.csv")["Body"].read()
          rows = len(body.decode().splitlines()) - 1
          return {"rows": rows, "ran_as": sts.get_caller_identity()["Arn"]}
      PY

      cat > deploy.sh <<'SH'
      #!/bin/sh
      # deploy.sh: packages the function and creates or updates it on floci.
      set -e
      cd "$(dirname "$0")"
      python3 - <<'PY'
      import pathlib, zipfile
      with zipfile.ZipFile("reports.zip", "w") as z:
          for f in pathlib.Path(".").glob("*.py"):
              z.write(f)
      PY
      ENV="Variables={REPORTS_KEY_ID=$(python3 -c 'import config; print(config.ACCESS_KEY_ID)'),REPORTS_SECRET=$(python3 -c 'import config; print(config.SECRET_ACCESS_KEY)')}"
      ROLE=arn:aws:iam::000000000000:role/reports
      if aws lambda get-function --function-name reports >/dev/null 2>&1; then
        aws lambda update-function-code --function-name reports --zip-file fileb://reports.zip >/dev/null
        aws lambda update-function-configuration --function-name reports --role "$ROLE" --environment "$ENV" >/dev/null
      else
        aws lambda create-function --function-name reports --runtime python3.12 --handler handler.handler \
          --role "$ROLE" --timeout 20 --zip-file fileb://reports.zip --environment "$ENV" >/dev/null
      fi
      rm -f reports.zip
      echo "deployed reports"
      SH
      chmod +x deploy.sh

      cat > invoke <<'SH'
      #!/bin/sh
      # invoke: calls reports once and prints what it returned.
      aws lambda invoke --function-name reports /tmp/reports.out >/dev/null && cat /tmp/reports.out && echo
      SH
      chmod +x invoke

      cat > README <<'TXT'
      reports is a Lambda function on floci. It reads s3://reports-data/daily/summary.csv
      with the access key of an IAM user, reports-bot. That key is in config.py,
      which is committed, and deploy.sh copies it into the function's environment.

        ./invoke      calls the function
        ./deploy.sh   deploys what is in this directory

      Fix it:

        - reports authenticates as its execution role, reports, and nothing else.
          The role exists and is allowed nothing yet.
        - No long-lived key is left in this directory or in the function's
          environment.
        - The leaked key cannot be used again by anyone who has a copy.
      TXT

      git init -q
      git add -A
      git commit -qm "reports: daily summary row count"
      ./deploy.sh >/dev/null
      echo "scenario ready — /root/reports: ./invoke, and read the README"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      if ! cd /root/reports 2>/dev/null; then
        echo "not yet: /root/reports is gone — reset the lesson to get it back"
        exit 1
      fi
      S=/var/lib/devopslings
      if [ ! -s $S/identity-not-keys.leaked ]; then
        echo "not yet: the scenario's records are missing — reset the lesson"
        exit 1
      fi
      read -r ak sk < $S/identity-not-keys.leaked
      rows=$(cat $S/identity-not-keys.rows)
      G=$(mktemp -d)
      trap 'rm -rf $G' EXIT
      keypat='(AKIA|ASIA)[A-Z0-9]{16}'

      hits=$( { grep -rIlE "$keypat" --exclude-dir=.git . || true; grep -rIlF -e "$sk" --exclude-dir=.git . || true; } | sort -u)
      if [ -n "$hits" ]; then
        echo "not yet: an access key is still written in this directory:"
        printf '%s\n' "$hits" | sed 's/^/         /'
        echo "         Anything committed here is readable by everyone who can clone it"
        exit 1
      fi
      if grep -rIlE 'aws_(access_key_id|secret_access_key|session_token)' --include='*.py' . >/dev/null 2>&1; then
        echo "not yet: the code still passes credentials to boto3 itself:"
        grep -rInE 'aws_(access_key_id|secret_access_key|session_token)' --include='*.py' . | sed 's/^/         /' || true
        echo "         Inside Lambda, boto3 finds the execution role's credentials on its own;"
        echo "         a key handed to it explicitly wins over the role"
        exit 1
      fi

      cfg=$(aws lambda get-function-configuration --function-name reports 2>/dev/null || true)
      if [ -z "$cfg" ]; then
        echo "not yet: there is no function called reports — run ./deploy.sh"
        exit 1
      fi
      envhits=$(jq -r --arg sk "$sk" '(.Environment.Variables // {}) | to_entries[]
        | select((.value | test("(AKIA|ASIA)[A-Z0-9]{16}")) or .value == $sk or .value == "test") | .key' <<<"$cfg")
      if [ -n "$envhits" ]; then
        echo "not yet: the deployed function's environment still holds a credential in:" $envhits
        echo "         Environment variables are part of the function's configuration: anyone"
        echo "         allowed lambda:GetFunctionConfiguration can read them. Updating a function"
        echo "         without --environment keeps the variables it already has, so removing"
        echo "         them from deploy.sh is not enough: deploy an empty set"
        exit 1
      fi
      role=$(jq -r .Role <<<"$cfg")
      if [ "$role" != "arn:aws:iam::000000000000:role/reports" ]; then
        echo "not yet: reports runs as $role; the README asks for the role reports"
        exit 1
      fi

      if ! aws lambda invoke --function-name reports $G/out > $G/meta 2>$G/err; then
        echo "not yet: the function could not be invoked: $(head -c 300 $G/err)"
        exit 1
      fi
      if jq -e '.FunctionError' $G/meta >/dev/null 2>&1 || ! jq -e '.rows' $G/out >/dev/null 2>&1; then
        out=$(head -c 400 $G/out)
        echo "not yet: reports fails when called: $out"
        case "$out" in
          *AccessDenied*|*"not authorized"*)
            echo "         The function now runs as the role, and the role is allowed nothing."
            echo "         Give it the one permission the function uses, on the one object it reads" ;;
          *InvalidAccessKeyId*|*"does not exist in our records"*)
            echo "         The deployed code still signs with a key that no longer exists. Deploy the"
            echo "         code from this directory" ;;
          *config*|*ImportError*|*ModuleNotFound*)
            echo "         handler.py imports something the deployed package no longer has" ;;
        esac
        exit 1
      fi
      got=$(jq -r .rows $G/out)
      ran_as=$(jq -r .ran_as $G/out)
      if [ "$got" != "$rows" ]; then
        echo "not yet: reports counted $got rows; summary.csv has $rows. Keep the function's"
        echo "         behaviour as it was: read daily/summary.csv and count its rows"
        exit 1
      fi
      case "$ran_as" in
        arn:aws:sts::000000000000:assumed-role/reports/*) ;;
        *:root)
          echo "not yet: reports ran as $ran_as, the account root. The function has root's"
          echo "         key in it somewhere; it must sign with its execution role's credentials"
          exit 1 ;;
        *)
          echo "not yet: reports ran as $ran_as, not its execution role reports"
          exit 1 ;;
      esac
      # The deployed package, not just the working tree, must be key-free.
      loc=$(aws lambda get-function --function-name reports --query Code.Location --output text 2>/dev/null || true)
      if [ -n "$loc" ] && [ "$loc" != None ] && curl -fsS -o $G/code.zip "$loc" 2>/dev/null; then
        if python3 - "$G/code.zip" "$sk" <<'PY'
      import re, sys, zipfile
      z = zipfile.ZipFile(sys.argv[1])
      text = "".join(z.read(n).decode(errors="replace") for n in z.namelist())
      bad = re.search(r"(AKIA|ASIA)[A-Z0-9]{16}", text) or sys.argv[2] in text
      sys.exit(0 if bad else 1)
      PY
        then
          echo "not yet: the deployed package still contains an access key. Deploy again"
          echo "         from this directory"
          exit 1
        fi
      fi

      keys=$(aws iam list-access-keys --user-name reports-bot --query 'AccessKeyMetadata[].[AccessKeyId,Status]' --output text 2>/dev/null || true)
      if printf '%s\n' "$keys" | grep -q "^$ak[[:space:]]*Active"; then
        echo "not yet: the leaked key $ak is still active. It is gone from the files, but not"
        echo "         from git history (git log -p shows it), nor from every clone, backup and"
        echo "         CI log that ever saw it. Removing a key from code does not un-leak it;"
        echo "         only IAM can make it worthless"
        exit 1
      fi
      if printf '%s\n' "$keys" | grep -q "^$ak"; then
        echo "not yet: the leaked key $ak is inactive, not deleted. Anyone allowed"
        echo "         iam:UpdateAccessKey can switch it back on. Nothing uses it: delete it"
        exit 1
      fi
      if [ -n "$keys" ]; then
        echo "not yet: reports-bot still has a key: $(printf '%s' "$keys" | tr '\t\n' '  ')"
        echo "         The function no longer needs one. A key nobody uses is a key nobody"
        echo "         rotates; delete it"
        exit 1
      fi
      echo "PASS — reports runs as its execution role, no key is left in the repository or"
      echo "       the function's environment, and the leaked key no longer exists."
---
