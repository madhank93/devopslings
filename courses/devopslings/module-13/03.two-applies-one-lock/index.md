---
kind: lesson
title: "two deploys at once, and the state forgot everything"
description: |
  Two people ran deploy.sh at the same moment. Both containers are running,
  the shared state says nothing exists, and every deploy since fails on a
  name conflict. Put state and reality back in agreement, then make a second
  deploy wait for the first instead of overwriting it.
name: two-applies-one-lock
slug: two-applies-one-lock
createdAt: "2026-10-15"

sandbox:
  stack: iac-stack
  service: ws

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      s3() { curl -sS -o /dev/null --aws-sigv4 "aws:amz:us-east-1:s3" --user "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY" "$@"; }
      docker rm -f $(docker ps -aq) >/dev/null 2>&1 || true
      s3 -X PUT http://minio:9000/tofu-state || true
      s3 -X DELETE http://minio:9000/tofu-state/shared/terraform.tfstate || true
      s3 -X DELETE http://minio:9000/tofu-state/shared/terraform.tfstate.tflock || true
      rm -rf /root/shared /var/lib/devopslings/lock-init
      install -d /root/shared /var/lib/devopslings
      cd /root/shared

      cat > versions.tf <<'TF'
      terraform {
        required_providers {
          docker = {
            source  = "kreuzwerker/docker"
            version = "4.6.0"
          }
        }

        # Shared state in MinIO. Credentials come from AWS_ACCESS_KEY_ID and
        # AWS_SECRET_ACCESS_KEY in the environment.
        backend "s3" {
          bucket = "tofu-state"
          key    = "shared/terraform.tfstate"
          region = "us-east-1"
          endpoints = {
            s3 = "http://minio:9000"
          }
          use_path_style              = true
          skip_credentials_validation = true
          skip_requesting_account_id  = true
          skip_metadata_api_check     = true
          skip_region_validation      = true
        }
      }

      provider "docker" {}
      TF

      cat > main.tf <<'TF'
      resource "docker_container" "web" {
        name    = "web"
        image   = "busybox:1.37.0"
        restart = "unless-stopped"
        command = ["sh", "-c", "echo shop > /www/index.html; exec httpd -f -p 8080 -h /www"]
      }

      resource "docker_container" "worker" {
        name    = "worker"
        image   = "busybox:1.37.0"
        restart = "unless-stopped"
        command = ["sh", "-c", "while true; do sleep 3600; done"]
      }
      TF

      cat > deploy.sh <<'SH'
      #!/bin/sh
      # The team's deploy. Everyone runs this, from their own checkout.
      set -e
      tofu init -input=false >/dev/null
      tofu apply -auto-approve -input=false
      SH
      chmod +x deploy.sh

      cat > README <<'TXT'
      On Tuesday two people ran ./deploy.sh at the same moment, each from their
      own checkout. Both said they started fine. Since then:

        - web and worker are running
        - the shared state in MinIO (tofu-state/shared/terraform.tfstate)
          records neither of them
        - every deploy fails: "The container name "/web" is already in use"

      1. Get the state and the running containers to agree, so deploy.sh
         works again and tofu plan shows no changes. web and worker hold
         nothing worth keeping.
      2. Make it impossible to happen again: when two deploys overlap, the
         second must wait for the first and then finish cleanly, not fail
         and not overwrite the first one's state.

      Keep the state where it is: same bucket, same key.
      TXT

      # Replay Tuesday: two checkouts deploy two seconds apart, the first one
      # still busy when the second starts.
      for c in a b; do
        install -d /var/lib/devopslings/lock-init/$c
        cp versions.tf main.tf deploy.sh /var/lib/devopslings/lock-init/$c/
        printf 'resource "terraform_data" "slow" {\n  provisioner "local-exec" {\n    command = "sleep 6"\n  }\n}\n' \
          > /var/lib/devopslings/lock-init/$c/slow.tf
        (cd /var/lib/devopslings/lock-init/$c && tofu init -input=false >/dev/null)
      done
      (cd /var/lib/devopslings/lock-init/a && ./deploy.sh >/dev/null 2>&1 || true) &
      sleep 2
      (cd /var/lib/devopslings/lock-init/b && ./deploy.sh >/dev/null 2>&1 || true)
      wait
      # The last write decides what survives. Make the outcome the same on
      # every machine: state that remembers nothing.
      cd /var/lib/devopslings/lock-init/a
      for r in $(tofu state list 2>/dev/null || true); do tofu state rm "$r" >/dev/null; done
      cd /root/shared
      rm -rf /var/lib/devopslings/lock-init
      docker inspect web worker >/dev/null
      tofu init -input=false >/dev/null
      echo "scenario ready — /root/shared: read the README, then try ./deploy.sh"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      if ! cd /root/shared 2>/dev/null || [ ! -f deploy.sh ]; then
        echo "not yet: /root/shared/deploy.sh is gone — reset the lesson to get it back"
        exit 1
      fi
      G=/var/lib/devopslings/two-applies
      rm -rf $G
      install -d $G
      err() { grep -A3 -m1 'Error' "$1" | sed 's/^/         /' || true; }

      # 1. Does the state agree with what is running?
      if ! tofu init -input=false -no-color >$G/init.log 2>&1; then
        echo "not yet: tofu init fails in /root/shared:"
        err $G/init.log
        exit 1
      fi
      state=$(tofu show -json -no-color 2>/dev/null || true)
      for n in web worker; do
        sid=$(jq -r --arg n "$n" '[.values.root_module.resources[]? | select(.type=="docker_container" and .values.name==$n) | .values.id][0] // empty' <<<"$state" 2>/dev/null || true)
        lid=$(docker inspect -f '{{.Id}}' "$n" 2>/dev/null || true)
        if [ -z "$sid" ] && [ -n "$lid" ]; then
          echo "not yet: $n is running, but the shared state has no record of it"
          echo "         every deploy will try to create it and fail on the name. Make the state"
          echo "         and the container agree first: import it, or remove it and deploy"
          exit 1
        elif [ -n "$sid" ] && [ "$sid" != "$lid" ]; then
          echo "not yet: the state records $n as ${sid:0:12}, but ${lid:+the running $n is ${lid:0:12}}${lid:-no $n is running}"
          exit 1
        elif [ -z "$sid" ]; then
          echo "not yet: $n is not running and not in state — run ./deploy.sh"
          exit 1
        fi
      done
      rc=0
      tofu plan -input=false -no-color -detailed-exitcode >$G/plan.log 2>&1 || rc=$?
      if [ "$rc" != 0 ]; then
        echo "not yet: tofu plan in /root/shared does not come back clean:"
        if [ "$rc" = 2 ]; then
          grep -E '^  # ' $G/plan.log | sed 's/^/         /' || true
        else
          err $G/plan.log
        fi
        exit 1
      fi

      # 2. Two checkouts of the student's code, each with a slow resource so
      # their applies are guaranteed to overlap.
      for c in a b; do
        install -d $G/$c
        find . -maxdepth 1 -type f ! -name '*.tfstate*' -exec cp {} $G/$c/ \;
        printf 'resource "terraform_data" "devopslings_hold" {\n  provisioner "local-exec" {\n    command = "sleep 8"\n  }\n}\n' > $G/$c/zz_devopslings_hold.tf
        if ! (cd $G/$c && tofu init -input=false -no-color >$G/init.log 2>&1); then
          echo "not yet: tofu init fails in a fresh checkout of /root/shared:"
          err $G/init.log
          exit 1
        fi
      done
      be=$(jq -c '.backend // {"type": "local"}' $G/a/.terraform/terraform.tfstate 2>/dev/null || echo '{"type": "local"}')
      if [ "$(jq -r .type <<<"$be")" != s3 ]; then
        echo "not yet: the backend is $(jq -r .type <<<"$be"), not s3. Two checkouts only share"
        echo "         state when it lives in one place both can reach; keep it in MinIO"
        exit 1
      fi
      if [ "$(jq -r '.config.bucket + "/" + .config.key' <<<"$be")" != tofu-state/shared/terraform.tfstate ]; then
        echo "not yet: state moved to $(jq -r '.config.bucket + "/" + .config.key' <<<"$be")."
        echo "         The README asks to keep it at tofu-state/shared/terraform.tfstate"
        exit 1
      fi
      if [ "$(jq -r '.config.use_lockfile' <<<"$be")" != true ]; then
        echo "not yet: the s3 backend takes no lock, so two applies can read the same state and"
        echo "         both write it back; whichever writes last wins. That is Tuesday."
        echo "         The s3 backend can lock with an object next to the state: look up use_lockfile"
        exit 1
      fi

      # 3. Reset to nothing, then two deploys two seconds apart.
      if ! (cd $G/a && tofu destroy -auto-approve -input=false -no-color -lock-timeout=120s >$G/destroy.log 2>&1); then
        echo "not yet: tofu destroy fails, so the grader cannot start from an empty state:"
        err $G/destroy.log
        exit 1
      fi
      ra=0 rb=0
      (cd $G/a && sh ./deploy.sh >$G/a.log 2>&1) & pa=$!
      sleep 2
      (cd $G/b && sh ./deploy.sh >$G/b.log 2>&1) || rb=$?
      wait $pa || ra=$?

      bad=""
      for c in a b; do
        r=$ra; [ $c = b ] && r=$rb
        [ "$r" = 0 ] && continue
        if grep -q 'Error acquiring the state lock' $G/$c.log; then
          if grep -q -- '-lock-timeout' deploy.sh; then
            bad="deploy $c gave up waiting for the lock. The lock works, but the
               other deploy held it for about 10 seconds and deploy.sh waits less than that"
          else
            bad="deploy $c hit the lock and failed at once. The lock works, but
               tofu gives up immediately unless told how long to wait, and deploy.sh
               does not tell it"
          fi
        else
          bad="deploy $c failed: $(grep -m1 'Error' $G/$c.log | sed 's/\x1b\[[0-9;]*m//g' | cut -c1-200 || true)"
        fi
        break
      done

      state=$(cd $G/a && tofu show -json -no-color 2>/dev/null || true)
      lost=""
      for n in web worker; do
        sid=$(jq -r --arg n "$n" '[.values.root_module.resources[]? | select(.type=="docker_container" and .values.name==$n) | .values.id][0] // empty' <<<"$state" 2>/dev/null || true)
        lid=$(docker inspect -f '{{.Id}}' "$n" 2>/dev/null || true)
        [ -n "$sid" ] && [ "$sid" = "$lid" ] || lost="$lost $n"
      done
      (cd $G/a && tofu state rm -lock-timeout=60s terraform_data.devopslings_hold >/dev/null 2>&1) || true

      if [ -n "$lost" ]; then
        echo "not yet: two overlapping deploys left the state out of step with reality again:"
        echo "         state does not match the running container for:$lost"
        if grep -q -- '-lock=false' deploy.sh; then
          echo "         deploy.sh runs with -lock=false, which skips the lock entirely"
        fi
        echo "         (the grader's two deploys: deploy a started, deploy b followed 2s later)"
        exit 1
      fi
      if [ -n "$bad" ]; then
        echo "not yet: $bad"
        exit 1
      fi
      if ! (cd /root/shared && tofu plan -input=false -no-color -detailed-exitcode >$G/plan.log 2>&1); then
        echo "not yet: after the two deploys, tofu plan in /root/shared is not clean"
        exit 1
      fi
      rm -rf $G

      echo "PASS — state and containers agree, the s3 backend locks, and a second deploy"
      echo "       waits for the first and then finishes with nothing left to do."
---
