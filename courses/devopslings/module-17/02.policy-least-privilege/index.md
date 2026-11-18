---
kind: lesson
title: "the policy that allows everything"
description: |
  ingest, a Lambda function, moves uploads from one prefix to another. Its
  role allows every action on every resource. Narrow the policy to what the
  function does, and prove that the actions next to those are denied.
name: policy-least-privilege
slug: policy-least-privilege
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
      for f in ingest ingest-probe; do curl -sS -o /dev/null -X DELETE "$F/$f" || true; done
      for p in $(aws iam list-role-policies --role-name ingest --query 'PolicyNames[]' --output text 2>/dev/null || true); do
        aws iam delete-role-policy --role-name ingest --policy-name "$p" || true
      done
      for p in $(aws iam list-attached-role-policies --role-name ingest --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || true); do
        aws iam detach-role-policy --role-name ingest --policy-arn "$p" || true
      done
      aws iam delete-role --role-name ingest 2>/dev/null || true
      for b in uploads billing; do aws s3 rb "s3://$b" --force >/dev/null 2>&1 || true; done
      rm -rf /root/ingest
      install -d /root/ingest

      aws s3 mb s3://uploads >/dev/null
      aws s3 mb s3://billing >/dev/null
      echo "invoice,amount" | aws s3 cp - s3://billing/2026-10/invoices.csv >/dev/null
      for n in a b c; do echo "upload $n" | aws s3 cp - "s3://uploads/incoming/$n.txt" >/dev/null; done

      aws iam create-role --role-name ingest --assume-role-policy-document \
        '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null

      cd /root/ingest
      cat > policy.json <<'JSON'
      {
        "Version": "2012-10-17",
        "Statement": [
          {
            "Effect": "Allow",
            "Action": "*",
            "Resource": "*"
          }
        ]
      }
      JSON
      aws iam put-role-policy --role-name ingest --policy-name ingest --policy-document file://policy.json

      cat > handler.py <<'PY'
      """ingest: moves every upload from incoming/ to processed/, upper-cased."""
      import boto3

      BUCKET = "uploads"
      s3 = boto3.client("s3")


      def handler(event, context):
          moved = []
          listing = s3.list_objects_v2(Bucket=BUCKET, Prefix="incoming/")
          for obj in listing.get("Contents", []):
              key = obj["Key"]
              body = s3.get_object(Bucket=BUCKET, Key=key)["Body"].read()
              dest = "processed/" + key[len("incoming/"):]
              s3.put_object(Bucket=BUCKET, Key=dest, Body=body.upper())
              s3.delete_object(Bucket=BUCKET, Key=key)
              moved.append(dest)
          return {"moved": moved}
      PY
      python3 -c 'import zipfile; zipfile.ZipFile("/tmp/ingest.zip", "w").write("handler.py")'
      aws lambda create-function --function-name ingest --runtime python3.12 --handler handler.handler \
        --role arn:aws:iam::000000000000:role/ingest --timeout 20 --zip-file fileb:///tmp/ingest.zip >/dev/null
      rm -f /tmp/ingest.zip

      cat > invoke <<'SH'
      #!/bin/sh
      # invoke: runs ingest once and prints what it moved, or the error.
      aws lambda invoke --function-name ingest /tmp/ingest.out >/dev/null && cat /tmp/ingest.out && echo
      SH
      chmod +x invoke

      cat > README <<'TXT'
      ingest is a Lambda function on floci (handler.py). It runs as the role
      ingest, whose only policy, also named ingest, is policy.json: every action
      on every resource.

        ./invoke                     runs it once
        aws s3 ls s3://uploads --recursive
        aws iam put-role-policy --role-name ingest --policy-name ingest \
            --policy-document file://policy.json

      Fix it:

        - ingest keeps working: uploads under incoming/ end up under processed/.
        - The role allows what the function does, and nothing next to it.
        - No "*" is left as an Action, and no Resource is "*".

      handler.py is not yours to change.
      TXT
      echo "scenario ready — /root/ingest: ./invoke, and read the README"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      if ! cd /root/ingest 2>/dev/null; then
        echo "not yet: /root/ingest is gone — reset the lesson to get it back"
        exit 1
      fi
      F=http://floci:4566/2015-03-31/functions
      G=
      tag=$RANDOM$RANDOM
      cleanup() {
        curl -sS -o /dev/null -X DELETE "$F/ingest-probe" 2>/dev/null || true
        for k in "incoming/probe-$tag.txt" "processed/probe-$tag.txt" "processed/check-$tag-1.txt" "processed/check-$tag-2.txt" \
                 "incoming/check-$tag-1.txt" "incoming/check-$tag-2.txt"; do
          aws s3api delete-object --bucket uploads --key "$k" >/dev/null 2>&1 || true
        done
        rm -rf "$G"
      }
      trap cleanup EXIT
      cleanup; G=$(mktemp -d)

      if ! aws iam get-role --role-name ingest >/dev/null 2>&1; then
        echo "not yet: the role ingest is gone — reset the lesson to get it back"
        exit 1
      fi
      role=$(aws lambda get-function-configuration --function-name ingest --query Role --output text 2>/dev/null || true)
      if [ "$role" != "arn:aws:iam::000000000000:role/ingest" ]; then
        echo "not yet: the function ingest must exist and run as the role ingest (it runs as '${role:-nothing}')"
        exit 1
      fi

      # Every policy the role has, inline and attached, as one list of statements.
      : > $G/docs
      for p in $(aws iam list-role-policies --role-name ingest --query 'PolicyNames[]' --output text); do
        aws iam get-role-policy --role-name ingest --policy-name "$p" --query PolicyDocument --output json \
          | jq -c --arg n "inline policy $p" '{name: $n, doc: .}' >> $G/docs
      done
      for arn in $(aws iam list-attached-role-policies --role-name ingest --query 'AttachedPolicies[].PolicyArn' --output text); do
        v=$(aws iam get-policy --policy-arn "$arn" --query Policy.DefaultVersionId --output text)
        aws iam get-policy-version --policy-arn "$arn" --version-id "$v" --query PolicyVersion.Document --output json \
          | jq -c --arg n "attached policy $arn" '{name: $n, doc: .}' >> $G/docs
      done
      if ! python3 - $G/docs > $G/static <<'PY'
      import json, sys
      def listify(v):
          return v if isinstance(v, list) else [v]
      problems = []
      for line in open(sys.argv[1]):
          p = json.loads(line)
          doc = p["doc"]
          if isinstance(doc, str):
              doc = json.loads(doc)
          for st in listify(doc.get("Statement", [])):
              if st.get("Effect") != "Allow":
                  continue
              for f in ("NotAction", "NotResource"):
                  if f in st:
                      problems.append(f"{p['name']} uses {f}, which allows everything except what it lists")
              for a in listify(st.get("Action", [])):
                  if "*" in a:
                      problems.append(f"{p['name']} allows Action {a!r}; name each action the function calls")
              for r in listify(st.get("Resource", [])):
                  if r in ("*", "arn:aws:s3:::*"):
                      problems.append(f"{p['name']} allows Resource {r!r}; name the bucket and prefix")
      for msg in problems:
          print("         " + msg)
      sys.exit(1 if problems else 0)
      PY
      then
        echo "not yet: a wildcard is still in the role's policies:"
        cat $G/static
        echo "         An Allow with a wildcard grants everything it matches, including actions"
        echo "         AWS adds later. A Deny beside it removes only what you thought to list"
        exit 1
      fi

      # The real job: two fresh uploads must be moved.
      for i in 1 2; do echo "check $i $tag" | aws s3 cp - "s3://uploads/incoming/check-$tag-$i.txt" >/dev/null; done
      aws lambda invoke --function-name ingest $G/out > $G/meta 2>$G/err || true
      if jq -e '.FunctionError' $G/meta >/dev/null 2>&1 || ! jq -e '.moved' $G/out >/dev/null 2>&1; then
        out=$(cat $G/out $G/err 2>/dev/null | head -c 600)
        act=$(grep -oE 'perform: [a-zA-Z0-9]+:[A-Za-z0-9]+' <<<"$out" | head -1 | cut -d' ' -f2 || true)
        if [ -n "$act" ]; then
          echo "not yet: ingest fails: the role is denied $act, which the function calls."
          echo "         Read handler.py for every call it makes, and the resource each acts on"
        else
          echo "not yet: ingest fails when called: $out"
        fi
        exit 1
      fi
      for i in 1 2; do
        got=$(aws s3 cp "s3://uploads/processed/check-$tag-$i.txt" - 2>/dev/null || true)
        if [ "$got" != "CHECK $i $tag" ]; then
          echo "not yet: ingest ran, but processed/check-$tag-$i.txt is not the upper-cased upload"
          exit 1
        fi
        if aws s3api head-object --bucket uploads --key "incoming/check-$tag-$i.txt" >/dev/null 2>&1; then
          echo "not yet: ingest ran, but left incoming/check-$tag-$i.txt behind"
          exit 1
        fi
      done

      # The probe: actions next to the real ones, run with the role's own credentials.
      echo "probe" | aws s3 cp - "s3://uploads/processed/probe-$tag.txt" >/dev/null
      cat > $G/probe.py <<'PY'
      import boto3, os
      from botocore.exceptions import ClientError
      s3 = boto3.client("s3")
      iam = boto3.client("iam")
      def handler(event, context):
          tag = event["tag"]
          calls = {
              "s3:PutObject on uploads/incoming/": lambda: s3.put_object(Bucket="uploads", Key=f"incoming/probe-{tag}.txt", Body=b"x"),
              "s3:GetObject on uploads/processed/": lambda: s3.get_object(Bucket="uploads", Key=f"processed/probe-{tag}.txt"),
              "s3:DeleteObject on uploads/processed/": lambda: s3.delete_object(Bucket="uploads", Key=f"processed/probe-{tag}.txt"),
              "s3:GetObject on the billing bucket": lambda: s3.get_object(Bucket="billing", Key="2026-10/invoices.csv"),
              "s3:GetBucketAcl on uploads": lambda: s3.get_bucket_acl(Bucket="uploads"),
              "iam:ListUsers": lambda: iam.list_users(),
          }
          out = {}
          for name, call in calls.items():
              try:
                  call()
                  out[name] = "allowed"
              except ClientError as e:
                  code = e.response["Error"]["Code"]
                  out[name] = "denied" if code in ("AccessDenied", "AccessDeniedException") else code
          return out
      PY
      ( cd $G && python3 -c 'import zipfile; zipfile.ZipFile("probe.zip", "w").write("probe.py")' )
      if ! aws lambda create-function --function-name ingest-probe --runtime python3.12 --handler probe.handler \
            --role arn:aws:iam::000000000000:role/ingest --timeout 30 --zip-file fileb://$G/probe.zip >/dev/null 2>$G/err; then
        echo "not yet: the grader could not deploy its probe: $(head -c 300 $G/err)"
        exit 1
      fi
      aws lambda invoke --function-name ingest-probe --payload "{\"tag\": \"$tag\"}" \
        --cli-binary-format raw-in-base64-out $G/probe.out >/dev/null 2>$G/err || true
      if ! jq -e 'type == "object" and (has("errorMessage") | not)' $G/probe.out >/dev/null 2>&1; then
        echo "not yet: the grader's probe failed to run: $(head -c 300 $G/probe.out $G/err 2>/dev/null)"
        exit 1
      fi
      allowed=$(jq -r 'to_entries[] | select(.value != "denied") | "\(.key) (\(.value))"' $G/probe.out)
      if [ -n "$allowed" ]; then
        echo "not yet: ingest works, and its role is also allowed what the function never does:"
        printf '%s\n' "$allowed" | sed 's/^/         /'
        echo "         The function reads and deletes under incoming/, writes under processed/, and"
        echo "         lists the bucket. Scope each action to the prefix it is used on"
        exit 1
      fi
      echo "PASS — ingest still moves uploads, no wildcard is left in its role's policies,"
      echo "       and the six actions next to the ones it uses are all denied."
---
