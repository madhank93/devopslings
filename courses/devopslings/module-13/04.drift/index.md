---
kind: lesson
title: "someone deleted cache by hand, and nothing noticed"
description: |
  The cache container was deleted outside OpenTofu. Nothing alerted, and
  nobody knows what else has drifted. Put the infrastructure back the way the
  code describes it, and add a CI job that finds the next drift on its own,
  without fixing anything by itself.
name: drift
slug: drift
createdAt: "2026-10-15"

sandbox:
  stack: iac-stack
  service: ws

tasks:
  init_scenario:
    init: true
    timeout_seconds: 120
    run: |
      docker rm -f $(docker ps -aq) >/dev/null 2>&1 || true
      docker network prune -f >/dev/null 2>&1 || true
      rm -rf /root/infra
      install -d /root/infra/ci /root/infra/.forgejo/workflows
      cd /root/infra

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
      resource "docker_network" "shop" {
        name = "shop"
      }

      resource "docker_container" "web" {
        name    = "web"
        image   = "busybox:1.37.0"
        restart = "unless-stopped"
        command = ["sh", "-c", "echo shop > /www/index.html; exec httpd -f -p 8080 -h /www"]
        networks_advanced {
          name = docker_network.shop.name
        }
      }

      resource "docker_container" "cache" {
        name    = "cache"
        image   = "busybox:1.37.0"
        restart = "unless-stopped"
        command = ["sh", "-c", "exec nc -lk -p 6379 -e cat"]
        networks_advanced {
          name = docker_network.shop.name
        }
      }

      resource "docker_container" "worker" {
        name    = "worker"
        image   = "busybox:1.37.0"
        restart = "unless-stopped"
        command = ["sh", "-c", "while true; do sleep 3600; done"]
        networks_advanced {
          name = docker_network.shop.name
        }
      }
      TF

      cat > .forgejo/workflows/deploy.yml <<'YML'
      on:
        push:
          branches: [main]
      jobs:
        deploy:
          runs-on: iac
          steps:
            - uses: actions/checkout@v4
            - run: tofu init -input=false
            - run: tofu apply -auto-approve -input=false
      YML

      cat > README <<'TXT'
      Someone deleted the cache container by hand. Nothing alerted.

      1. Put the infrastructure back to what the code describes. The code is
         right; the container's absence is the mistake.

      2. Write ci/drift-check.sh, a check CI can run on a schedule from this
         directory. It must only look, never change anything, and exit:
           0  when the real infrastructure matches the code
           2  when it has drifted
           anything else  when the check itself could not run
         (CI treats 0 as fine, 2 as "open a drift ticket", anything else as
         "the check is broken". An exit 0 from a check that could not run
         would hide drift forever.)

      3. Add .forgejo/workflows/drift.yml: a scheduled job that runs
         ci/drift-check.sh.
      TXT

      tofu init -input=false >/dev/null
      tofu apply -auto-approve -input=false >/dev/null
      docker rm -f cache >/dev/null
      echo "scenario ready — /root/infra: cache has been deleted behind OpenTofu's back"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      if ! cd /root/infra 2>/dev/null; then
        echo "not yet: /root/infra is gone — reset the lesson to get it back"
        exit 1
      fi
      G=/var/lib/devopslings/drift
      install -d $G
      err() { grep -A3 -m1 'Error' "$1" | sed 's/^/         /' || true; }

      if ! tofu init -input=false -no-color >$G/init.log 2>&1; then
        echo "not yet: tofu init fails in /root/infra:"
        err $G/init.log
        exit 1
      fi
      rc=0
      tofu plan -input=false -no-color -detailed-exitcode -out=$G/plan >$G/plan.log 2>&1 || rc=$?
      if [ "$rc" = 1 ]; then
        echo "not yet: tofu plan fails:"
        err $G/plan.log
        exit 1
      fi
      pj=$(tofu show -json -no-color $G/plan)
      cfg=$(jq -r '[.configuration.root_module.resources[]? | .address] | sort | join(" ")' <<<"$pj")
      want="docker_container.cache docker_container.web docker_container.worker docker_network.shop"
      if [ "$cfg" != "$want" ]; then
        echo "not yet: the code now declares: ${cfg:-nothing}"
        echo "         it should still be: $want"
        echo "         the code was right; deleting cache from it makes the plan quiet by agreeing with the mistake"
        exit 1
      fi

      # 1. Reconciled: cache is back and everything matches the code.
      if [ "$rc" = 2 ]; then
        echo "not yet: the infrastructure still differs from the code. tofu plan wants:"
        jq -r '.resource_changes[]? | select(.change.actions != ["no-op"]) | "           \(.change.actions | join("/")) \(.address)"' <<<"$pj" || true
        if ! jq -e '.prior_state.values.root_module.resources[]? | select(.address=="docker_container.cache")' <<<"$pj" >/dev/null 2>&1 \
           && [ -f terraform.tfstate.backup ] && jq -e '.resources[] | select(.name=="cache")' terraform.tfstate.backup >/dev/null 2>&1; then
          echo "         state no longer lists cache at all: an apply -refresh-only accepts the"
          echo "         deletion as the new truth. The plan still shows what the code wants"
        fi
        exit 1
      fi
      for n in web cache worker; do
        if [ "$(docker inspect -f '{{.State.Running}}' $n 2>/dev/null || true)" != true ]; then
          echo "not yet: $n is not running, yet the plan is clean"
          exit 1
        fi
      done

      # 2. The drift check.
      if [ ! -f ci/drift-check.sh ]; then
        echo "not yet: the infrastructure is back, but there is no ci/drift-check.sh,"
        echo "         so the next deletion will go unnoticed the same way"
        exit 1
      fi
      runcheck() {
        local rc=0
        timeout 120 env "$@" bash ci/drift-check.sh >$G/check.log 2>&1 || rc=$?
        echo $rc
      }
      # show: the lines of the check's output that say what it saw.
      show() {
        { grep -m3 -E 'Plan:|No changes|Error' $G/check.log || tail -n 3 $G/check.log; } \
          | sed 's/\x1b\[[0-9;]*m//g; s/^[│╷╵ ]*//; s/^/           | /' | awk 1 || true
      }

      r=$(runcheck DEVOPSLINGS=1)
      if [ "$r" != 0 ]; then
        echo "not yet: ci/drift-check.sh exited $r on infrastructure that matches the code; it must exit 0"
        show
        exit 1
      fi

      # Drift the grader causes, and undoes before it finishes.
      docker rm -f worker >/dev/null
      r=$(runcheck DEVOPSLINGS=1)
      healed=$(docker inspect -f '{{.State.Running}}' worker 2>/dev/null || true)
      tofu apply -auto-approve -input=false -no-color >$G/restore.log 2>&1 || true
      if [ "$healed" = true ]; then
        echo "not yet: the grader deleted worker, and running ci/drift-check.sh put it back."
        echo "         A detection step must only look. A scheduled job that applies whatever"
        echo "         it finds also undoes deliberate emergency changes, with nobody reviewing them"
        exit 1
      fi
      if [ "$r" != 2 ]; then
        echo "not yet: the grader deleted worker, and ci/drift-check.sh exited $r, not 2:"
        show
        if [ "$r" = 0 ]; then
          if grep -q -- '-refresh=false' ci/drift-check.sh; then
            echo "         -refresh=false compares the code with the state only, and never looks at"
            echo "         the real containers, so a deletion is invisible to it"
          else
            echo "         tofu plan exits 0 whether or not it finds changes, unless asked to say otherwise"
          fi
        fi
        exit 1
      fi

      r=$(runcheck DOCKER_HOST=tcp://127.0.0.1:1)
      if [ "$r" = 0 ] || [ "$r" = 2 ]; then
        echo "not yet: with the Docker daemon unreachable, ci/drift-check.sh exited $r."
        echo "         The check could not look at anything, so it must exit something other than"
        echo "         0 (all fine) or 2 (drift found):"
        show
        exit 1
      fi

      if ! out=$(tofu plan -input=false -no-color -detailed-exitcode 2>&1); then
        echo "not yet: after the grader put worker back, the plan is not clean:"
        grep -E '^  # ' <<<"$out" | sed 's/^/         /' || true
        exit 1
      fi

      # 3. Scheduled in CI.
      wf=.forgejo/workflows/drift.yml
      if [ ! -f $wf ]; then
        echo "not yet: the check works, but nothing runs it: there is no $wf"
        exit 1
      fi
      if ! grep -qE '^[[:space:]]*schedule:' $wf || ! grep -qE 'cron:' $wf; then
        echo "not yet: $wf has no schedule. Drift happens between pushes, so a job"
        echo "         that only runs on push never sees it. Use on: schedule: with a cron line"
        exit 1
      fi
      if ! grep -q 'drift-check.sh' $wf; then
        echo "not yet: $wf is scheduled but never runs ci/drift-check.sh"
        exit 1
      fi
      rm -rf $G

      echo "PASS — cache is back, the drift check exits 0, 2 and an error for the three cases,"
      echo "       never changes anything, and runs on a schedule."
---
