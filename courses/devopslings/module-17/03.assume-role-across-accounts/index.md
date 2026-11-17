---
kind: lesson
title: "the role that trusts everyone"
description: |
  deploy, a role in the production account, is meant for the CI system in the
  tools account. Its trust policy accepts any principal in any account.
  Make it assumable by CI and nobody else, and say which policy did that.
name: assume-role-across-accounts
slug: assume-role-across-accounts
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
      # floci's IAM and STS act as the root of whichever account a 12-digit
      # access key names.
      as() { local a=$1; shift; AWS_ACCESS_KEY_ID=$a AWS_SECRET_ACCESS_KEY=x "$@"; }
      nuke_role() {
        for p in $(as $1 aws iam list-role-policies --role-name $2 --query 'PolicyNames[]' --output text 2>/dev/null || true); do
          as $1 aws iam delete-role-policy --role-name $2 --policy-name "$p" || true
        done
        for p in $(as $1 aws iam list-attached-role-policies --role-name $2 --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || true); do
          as $1 aws iam detach-role-policy --role-name $2 --policy-arn "$p" || true
        done
        as $1 aws iam delete-role --role-name $2 2>/dev/null || true
      }
      nuke_user() {
        for k in $(as $1 aws iam list-access-keys --user-name $2 --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null || true); do
          as $1 aws iam delete-access-key --user-name $2 --access-key-id "$k" || true
        done
        for p in $(as $1 aws iam list-user-policies --user-name $2 --query 'PolicyNames[]' --output text 2>/dev/null || true); do
          as $1 aws iam delete-user-policy --user-name $2 --policy-name "$p" || true
        done
        as $1 aws iam delete-user --user-name $2 2>/dev/null || true
      }
      nuke_role 000000000000 deploy
      nuke_role 111111111111 ci
      nuke_role 111111111111 sandbox
      nuke_user 111111111111 runner
      nuke_user 222222222222 contractor
      rm -rf /root/deploy
      install -d /root/deploy $S

      ASSUME_ANY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"sts:AssumeRole","Resource":"*"}]}'
      # Tools account: a runner user, and two roles it can become. Both roles
      # may try to assume roles anywhere; their own account allows it.
      as 111111111111 aws iam create-user --user-name runner >/dev/null
      as 111111111111 aws iam put-user-policy --user-name runner --policy-name assume --policy-document "$ASSUME_ANY"
      as 111111111111 aws iam create-access-key --user-name runner --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text > $S/assume-role.runner
      for r in ci sandbox; do
        as 111111111111 aws iam create-role --role-name $r --assume-role-policy-document \
          '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam::111111111111:user/runner"},"Action":"sts:AssumeRole"}]}' >/dev/null
        as 111111111111 aws iam put-role-policy --role-name $r --policy-name assume --policy-document "$ASSUME_ANY"
      done
      # A contractor's account, unrelated to either.
      as 222222222222 aws iam create-user --user-name contractor >/dev/null
      as 222222222222 aws iam put-user-policy --user-name contractor --policy-name assume --policy-document "$ASSUME_ANY"
      as 222222222222 aws iam create-access-key --user-name contractor --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text > $S/assume-role.contractor

      cd /root/deploy
      cat > trust.json <<'JSON'
      {
        "Version": "2012-10-17",
        "Statement": [
          {
            "Effect": "Allow",
            "Principal": { "AWS": "*" },
            "Action": "sts:AssumeRole"
          }
        ]
      }
      JSON
      cat > permissions.json <<'JSON'
      {
        "Version": "2012-10-17",
        "Statement": [
          {
            "Effect": "Allow",
            "Action": ["s3:PutObject", "s3:GetObject"],
            "Resource": "arn:aws:s3:::releases/*"
          },
          {
            "Effect": "Allow",
            "Action": ["lambda:UpdateFunctionCode", "lambda:GetFunction"],
            "Resource": "arn:aws:lambda:us-east-1:000000000000:function:*"
          }
        ]
      }
      JSON
      aws iam create-role --role-name deploy --assume-role-policy-document file://trust.json >/dev/null
      aws iam put-role-policy --role-name deploy --policy-name deploy --policy-document file://permissions.json

      cat > become <<'SH'
      #!/bin/sh
      # become ci|sandbox|contractor: prints the identity you get when that
      # principal assumes the production deploy role, or the error.
      set -e
      S=/var/lib/devopslings
      case "$1" in
        ci|sandbox)
          read -r ak sk < $S/assume-role.runner
          creds=$(AWS_ACCESS_KEY_ID=$ak AWS_SECRET_ACCESS_KEY=$sk aws sts assume-role \
            --role-arn "arn:aws:iam::111111111111:role/$1" --role-session-name "$1-session" \
            --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text)
          set -- $creds
          export AWS_ACCESS_KEY_ID=$1 AWS_SECRET_ACCESS_KEY=$2 AWS_SESSION_TOKEN=$3 ;;
        contractor)
          read -r ak sk < $S/assume-role.contractor
          export AWS_ACCESS_KEY_ID=$ak AWS_SECRET_ACCESS_KEY=$sk ;;
        *) echo "usage: become ci|sandbox|contractor" >&2; exit 2 ;;
      esac
      echo "as $(aws sts get-caller-identity --query Arn --output text):"
      aws sts assume-role --role-arn arn:aws:iam::000000000000:role/deploy \
        --role-session-name probe-session --query AssumedRoleUser.Arn --output text
      SH
      chmod +x become

      cat > ANSWER <<'TXT'
      # Replace each ? with trust or permission.
      #
      # Which of deploy's two policies decides who can become the role?
      who_can_assume=?
      # Which one decides what the role can do once someone has become it?
      what_it_can_do=?
      TXT

      cat > README <<'TXT'
      deploy is a role in the production account (000000000000). It exists for
      one principal: the ci role in the tools account,
      arn:aws:iam::111111111111:role/ci.

        trust.json        deploy's trust policy
        permissions.json  deploy's permission policy (inline, named deploy)
        ./become ci       tries to assume deploy as tools:ci
        ./become sandbox  ... as tools:sandbox, another role in the tools account
        ./become contractor  ... as a user in an unrelated account, 222222222222

      Right now all three succeed. Fix it:

        - ci can still assume deploy.
        - sandbox and contractor cannot, nor can anyone else.
        - Fill in ANSWER.
      TXT
      echo "scenario ready — /root/deploy: ./become ci, and read the README"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 120
    run: |
      if ! cd /root/deploy 2>/dev/null; then
        echo "not yet: /root/deploy is gone — reset the lesson to get it back"
        exit 1
      fi
      S=/var/lib/devopslings
      if [ ! -s $S/assume-role.runner ] || [ ! -s $S/assume-role.contractor ]; then
        echo "not yet: the scenario's records are missing — reset the lesson"
        exit 1
      fi
      CI=arn:aws:iam::111111111111:role/ci
      DEPLOY=arn:aws:iam::000000000000:role/deploy

      if [ ! -f ANSWER ]; then
        echo "not yet: /root/deploy/ANSWER is missing — reset the lesson to get the template back"
        exit 1
      fi
      tok() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\([A-Za-z?]*\).*/\1/p" ANSWER | head -1 | tr 'A-Z' 'a-z'; }
      who=$(tok who_can_assume)
      what=$(tok what_it_can_do)
      for v in "who_can_assume:$who" "what_it_can_do:$what"; do
        case "${v#*:}" in
          trust|permission) ;;
          *) echo "not yet: ANSWER needs ${v%%:*}=trust or ${v%%:*}=permission"; exit 1 ;;
        esac
      done

      doc=$(aws iam get-role --role-name deploy --query Role.AssumeRolePolicyDocument --output json 2>/dev/null || true)
      if [ -z "$doc" ]; then
        echo "not yet: the role deploy is gone — reset the lesson to get it back"
        exit 1
      fi
      # Allowed principals, plus whether a Condition guards them.
      principals=$(jq -r '(if type == "string" then fromjson else . end) | [.Statement] | flatten[]
        | select(.Effect == "Allow")
        | (.Principal.AWS // (if .Principal == "*" then "*" else empty end)) as $p
        | ([$p] | flatten[]) + (if .Condition then " +condition" else "" end)' <<<"$doc")
      if grep -q '^\* +condition' <<<"$principals"; then
        echo "not yet: the trust policy still names Principal \"*\" and narrows it with a Condition."
        echo "         On AWS that can work. floci does not evaluate conditions in trust"
        echo "         policies, and a reviewer reading Principal \"*\" has to read every condition"
        echo "         to know who is trusted. Name the principal itself"
        exit 1
      fi
      if grep -qE '^(arn:aws:iam::)?[0-9]{12}(:root)?( |$)' <<<"$principals"; then
        acct=$(grep -oE '[0-9]{12}' <<<"$principals" | head -1)
        echo "not yet: the trust policy names the whole account $acct. That trusts every"
        echo "         principal in it whose own policies allow sts:AssumeRole, which includes"
        echo "         sandbox. On AWS it is how you hand the decision to that account's admins;"
        echo "         here the README asks for one role. Name it"
        exit 1
      fi

      read -r rak rsk < $S/assume-role.runner
      read -r cak csk < $S/assume-role.contractor
      # try PRINCIPAL: "ok" if PRINCIPAL can assume deploy, else the error.
      try() {
        local e=()
        case "$1" in
          ci|sandbox)
            local c
            c=$(AWS_ACCESS_KEY_ID=$rak AWS_SECRET_ACCESS_KEY=$rsk aws sts assume-role \
                  --role-arn "arn:aws:iam::111111111111:role/$1" --role-session-name grader-$1 \
                  --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text 2>&1) || { echo "setup: $c"; return; }
            set -- $c
            e=(AWS_ACCESS_KEY_ID=$1 AWS_SECRET_ACCESS_KEY=$2 AWS_SESSION_TOKEN=$3) ;;
          runner) e=(AWS_ACCESS_KEY_ID=$rak AWS_SECRET_ACCESS_KEY=$rsk) ;;
          contractor) e=(AWS_ACCESS_KEY_ID=$cak AWS_SECRET_ACCESS_KEY=$csk) ;;
        esac
        if env "${e[@]}" aws sts assume-role --role-arn $DEPLOY --role-session-name grader-probe >/dev/null 2>&1; then
          echo ok
        else
          echo denied
        fi
      }
      r=$(try ci)
      case "$r" in
        ok) ;;
        setup:*)
          echo "not yet: the grader could not become tools:ci (${r#setup: }). That role belongs to the"
          echo "         scenario; reset the lesson to restore it"
          exit 1 ;;
        *)
          echo "not yet: tools:ci can no longer assume deploy. The trust policy has to name"
          echo "         $CI as an AWS principal, exactly"
          exit 1 ;;
      esac
      leaks=""
      for p in sandbox contractor runner; do
        [ "$(try $p)" = ok ] && leaks="$leaks $p"
      done
      if [ -n "$leaks" ]; then
        echo "not yet: tools:ci can assume deploy, and so can:$leaks."
        if grep -q '^\*' <<<"$principals" && grep -q '"Deny"' <<<"$doc"; then
          echo "         The trust policy still allows Principal \"*\", and a Deny only removes the"
          echo "         principals you thought to list. Allow the one principal instead"
        elif grep -q '^\*' <<<"$principals"; then
          echo "         The trust policy still allows Principal \"*\". The permission policy only"
          echo "         limits what a session of deploy may do once it exists. Who may create"
          echo "         that session is decided by the trust policy alone"
        else
          echo "         The trust policy allows more principals than $CI"
        fi
        exit 1
      fi

      if [ "$who" != trust ] || [ "$what" != permission ]; then
        echo "not yet: deploy now trusts only tools:ci, and ANSWER says who_can_assume=$who,"
        echo "         what_it_can_do=$what. Look at which file you changed to get here, and"
        echo "         what the other one still controls"
        exit 1
      fi
      echo "PASS — only tools:ci can assume deploy; sandbox, the contractor and the runner"
      echo "       itself are refused by the trust policy."
---
