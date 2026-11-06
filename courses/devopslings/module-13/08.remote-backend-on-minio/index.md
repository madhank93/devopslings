---
kind: lesson
title: "the state file is committed to git"
description: |
  The platform state lives in a file on one laptop, and to share it someone
  committed it to git. Move it to the shared s3 backend on MinIO, with
  locking, without losing track of a single running container, and get it
  out of the repository.
name: remote-backend-on-minio
slug: remote-backend-on-minio
createdAt: "2026-10-15"

sandbox:
  stack: iac-stack
  service: ws

tasks:
  init_scenario:
    init: true
    timeout_seconds: 120
    run: |
      s3() { curl -sS -o /dev/null --aws-sigv4 "aws:amz:us-east-1:s3" --user "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY" "$@"; }
      docker rm -f $(docker ps -aq) >/dev/null 2>&1 || true
      docker network prune -f >/dev/null 2>&1 || true
      s3 -X PUT http://minio:9000/tofu-state || true
      s3 -X DELETE http://minio:9000/tofu-state/platform/terraform.tfstate || true
      s3 -X DELETE http://minio:9000/tofu-state/platform/terraform.tfstate.tflock || true
      rm -rf /root/platform
      install -d /root/platform /var/lib/devopslings
      cd /root/platform
      git init -q

      cat > versions.tf <<'TF'
      terraform {
        required_providers {
          docker = {
            source  = "kreuzwerker/docker"
            version = "4.6.0"
          }
        }
      }

      provider "docker" {}
      TF

      cat > main.tf <<'TF'
      resource "docker_network" "platform" {
        name = "platform"
      }

      resource "docker_container" "api" {
        name    = "api"
        image   = "busybox:1.37.0"
        restart = "unless-stopped"
        command = ["sh", "-c", "echo platform-api > /www/index.html; exec httpd -f -p 8080 -h /www"]
        networks_advanced {
          name = docker_network.platform.name
        }
      }

      resource "docker_container" "queue" {
        name    = "queue"
        image   = "busybox:1.37.0"
        restart = "unless-stopped"
        command = ["sh", "-c", "exec nc -lk -p 5672 -e cat"]
        networks_advanced {
          name = docker_network.platform.name
        }
      }
      TF
      printf '.terraform/\n' > .gitignore
      tofu init -input=false >/dev/null
      tofu apply -auto-approve -input=false >/dev/null
      git add -A
      git commit -qm "Commit the state so everyone can apply"

      cat > README <<'TXT'
      The state for this directory is terraform.tfstate, and it is committed
      to git so that others can apply. Move it to the shared backend:

        - s3 backend, bucket tofu-state, key platform/terraform.tfstate,
          endpoint http://minio:9000 (path-style), with state locking on
        - every resource the state knows about now must still be known after
          the move, and tofu plan must show no changes
        - no state file in git any more, and .gitignore keeps it out
        - no credentials in any .tf file: AWS_ACCESS_KEY_ID and
          AWS_SECRET_ACCESS_KEY are already set in the environment

      Commit your changes.
      TXT

      {
        echo "api=$(docker inspect -f '{{.Id}}' api)"
        echo "queue=$(docker inspect -f '{{.Id}}' queue)"
        echo "net=$(docker network inspect -f '{{.Id}}' platform)"
      } > /var/lib/devopslings/remote-backend-on-minio.env
      echo "scenario ready — /root/platform: state is in git; move it to MinIO"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      if ! cd /root/platform 2>/dev/null || [ ! -f /var/lib/devopslings/remote-backend-on-minio.env ]; then
        echo "not yet: /root/platform is gone — reset the lesson to get it back"
        exit 1
      fi
      . /var/lib/devopslings/remote-backend-on-minio.env
      G=/var/lib/devopslings/remote-backend
      rm -rf $G
      install -d $G/copy
      err() { grep -A3 -m1 'Error' "$1" | sed 's/^/         /' || true; }

      for p in "api $api" "queue $queue"; do
        set -- $p
        if [ "$(docker inspect -f '{{.Id}}' $1 2>/dev/null || true)" != "$2" ]; then
          echo "not yet: the $1 container is not the original any more: it was destroyed or replaced."
          echo "         Moving state must not touch infrastructure. Reset the lesson"
          exit 1
        fi
      done
      if [ "$(docker network inspect -f '{{.Id}}' platform 2>/dev/null || true)" != "$net" ]; then
        echo "not yet: the platform network is not the original any more. Reset the lesson"
        exit 1
      fi

      if grep -nE '^[^#]*\b(access_key|secret_key|AKIA|devopslings-minio)\b' ./*.tf >/dev/null 2>&1; then
        echo "not yet: a .tf file holds credentials:"
        grep -nE '^[^#]*\b(access_key|secret_key|devopslings-minio)\b' ./*.tf | sed 's/^/           /' || true
        echo "         .tf files are committed. The s3 backend reads AWS_ACCESS_KEY_ID and"
        echo "         AWS_SECRET_ACCESS_KEY from the environment, which are already set"
        exit 1
      fi

      # What a colleague gets from a fresh clone: the backend has to be in
      # the committed code, not in flags someone typed once.
      git archive HEAD | tar -x -C $G/copy
      if ! (cd $G/copy && tofu init -input=false -no-color >$G/init.log 2>&1); then
        echo "not yet: tofu init fails in a fresh clone of the committed code:"
        err $G/init.log
        if git ls-tree -r --name-only HEAD | grep -q 'tfstate'; then
          echo "         The commit still carries a state file, so every clone finds local state"
          echo "         next to an s3 backend and stops to ask about migrating it. Untrack it"
        fi
        exit 1
      fi
      be=$(jq -c '.backend // {"type": "local"}' $G/copy/.terraform/terraform.tfstate 2>/dev/null || echo '{"type": "local"}')
      if [ "$(jq -r .type <<<"$be")" != s3 ]; then
        echo "not yet: a fresh clone of the last commit uses the $(jq -r .type <<<"$be") backend, not s3."
        echo "         The backend block has to be committed, in the code, so every checkout"
        echo "         and every CI run reads the same state"
        exit 1
      fi
      where=$(jq -r '.config.bucket + "/" + .config.key' <<<"$be")
      if [ "$where" != tofu-state/platform/terraform.tfstate ]; then
        echo "not yet: the backend points at $where; the README asks for tofu-state/platform/terraform.tfstate"
        exit 1
      fi
      if [ "$(jq -r .config.use_lockfile <<<"$be")" != true ]; then
        echo "not yet: the s3 backend has no locking, so two applies can overwrite each other's"
        echo "         state. Shared state needs a lock: see use_lockfile"
        exit 1
      fi

      remote=$(curl -fsS --aws-sigv4 "aws:amz:us-east-1:s3" --user "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY" \
        http://minio:9000/tofu-state/platform/terraform.tfstate 2>/dev/null || true)
      n=$(jq -r '[.resources[]?] | length' <<<"$remote" 2>/dev/null || echo 0)
      if [ "${n:-0}" = 0 ]; then
        echo "not yet: the state in MinIO is ${remote:+empty}${remote:-missing}: none of the three resources made the move."
        echo "         Switching backends with -reconfigure starts from an empty state; the"
        echo "         existing one has to be migrated. The local terraform.tfstate still has it"
        exit 1
      fi
      if [ "$n" != 3 ]; then
        echo "not yet: the state in MinIO holds $n resources; the local state held three"
        echo "         (docker_network.platform, docker_container.api, docker_container.queue)."
        echo "         Every one has to come across, still managed"
        exit 1
      fi
      rc=0
      (cd $G/copy && tofu plan -input=false -no-color -detailed-exitcode -lock-timeout=60s >$G/plan.log 2>&1) || rc=$?
      if [ "$rc" != 0 ]; then
        echo "not yet: a fresh clone reading the state from MinIO does not get a clean plan:"
        if [ "$rc" = 2 ]; then grep -E '^  # ' $G/plan.log | sed 's/^/         /' || true; else err $G/plan.log; fi
        exit 1
      fi

      tracked=$(git ls-tree -r --name-only HEAD | grep -E 'tfstate' || true)
      if [ -n "$tracked" ]; then
        echo "not yet: the last commit still contains:"
        sed 's/^/           /' <<<"$tracked"
        echo "         Adding it to .gitignore does not untrack a file git already has"
        exit 1
      fi
      for f in terraform.tfstate terraform.tfstate.backup .terraform/terraform.tfstate; do
        if ! git check-ignore -q --no-index "$f"; then
          echo "not yet: $f is not ignored, so the next git add -A puts state back in the repository"
          exit 1
        fi
      done
      if ! git diff --quiet HEAD -- .gitignore 2>/dev/null || ! git ls-files --error-unmatch .gitignore >/dev/null 2>&1; then
        echo "not yet: .gitignore has changes that are not committed; a fresh clone would not have them"
        exit 1
      fi
      rm -rf $G

      echo "PASS — state lives in MinIO with locking, every resource came with it, a fresh"
      echo "       clone plans clean, and git no longer holds the state."
---
