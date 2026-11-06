---
kind: lesson
title: "a one-line rename, and the plan deletes the database"
description: |
  A harmless-looking rename of the database volume plans a destroy, and the
  only thing between it and the data is someone reading the plan. Make that
  plan fail on its own, while the routine change to web still applies.
name: prevent-destroy
slug: prevent-destroy
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
      docker volume rm db-data pgdata >/dev/null 2>&1 || true
      rm -rf /root/db
      install -d /root/db /var/lib/devopslings
      cd /root/db

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
      resource "docker_volume" "db_data" {
        name = "db-data"
      }

      resource "docker_container" "db" {
        name    = "db"
        image   = "busybox:1.37.0"
        restart = "unless-stopped"
        command = ["sh", "-c", "while true; do sleep 3600; done"]
        volumes {
          volume_name    = docker_volume.db_data.name
          container_path = "/var/lib/db"
        }
      }

      resource "docker_container" "web" {
        name    = "web"
        image   = "busybox:1.37.0"
        restart = "unless-stopped"
        env     = ["RELEASE=1"]
        command = ["sh", "-c", "echo release $RELEASE > /www/index.html; exec httpd -f -p 8080 -h /www"]
      }
      TF

      cat > README <<'TXT'
      Two changes are waiting.

        1. web moves to RELEASE=2. Routine: web holds nothing, and it is
           fine for the plan to recreate it. Apply it.

        2. A colleague's branch renames the volume db-data to pgdata, "to
           match the docs". That plan destroys db-data, and the database
           with it. Last time, a reviewer caught it by reading the plan.

      Make any plan that would destroy db-data fail on its own, without
      anyone having to read it. Recreating the db container is fine; the
      data lives in the volume. Routine changes like (1) must still apply.
      TXT

      tofu init -input=false >/dev/null
      tofu apply -auto-approve -input=false >/dev/null
      docker exec db sh -c 'for i in $(seq 1 200); do echo "order-$i"; done > /var/lib/db/orders'
      echo "vol=$(docker volume inspect -f '{{.CreatedAt}}' db-data)" > /var/lib/devopslings/prevent-destroy.env
      echo "scenario ready — /root/db: read the README"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      if ! cd /root/db 2>/dev/null || [ ! -f /var/lib/devopslings/prevent-destroy.env ]; then
        echo "not yet: /root/db is gone — reset the lesson to get it back"
        exit 1
      fi
      . /var/lib/devopslings/prevent-destroy.env
      G=/var/lib/devopslings/prevent-destroy
      rm -rf $G
      install -d $G
      err() { grep -A3 -m1 'Error' "$1" | sed 's/^/         /' || true; }

      now=$(docker volume inspect -f '{{.CreatedAt}}' db-data 2>/dev/null || true)
      rows=$(docker run --rm -v db-data:/d busybox:1.37.0 sh -c 'grep -c order- /d/orders 2>/dev/null || true' 2>/dev/null || true)
      if [ "$now" != "$vol" ] || [ "${rows:-0}" != 200 ]; then
        echo "not yet: db-data is ${now:+not the original volume}${now:-gone}; it holds ${rows:-0} of 200 orders."
        echo "         That is the loss this lesson prevents. Reset the lesson to get the data back"
        exit 1
      fi

      if ! tofu init -input=false -no-color >$G/init.log 2>&1; then
        echo "not yet: tofu init fails:"
        err $G/init.log
        exit 1
      fi
      rc=0
      tofu plan -input=false -no-color -detailed-exitcode >$G/plan.log 2>&1 || rc=$?
      if [ "$rc" != 0 ]; then
        echo "not yet: tofu plan in /root/db is not clean:"
        if [ "$rc" = 2 ]; then grep -E '^  # ' $G/plan.log | sed 's/^/         /' || true; else err $G/plan.log; fi
        if grep -q 'cannot be destroyed' $G/plan.log; then
          echo "         A routine change recreates a container, and a destroy guard on it"
          echo "         blocks that. Guard what holds data, not everything"
        fi
        exit 1
      fi
      if ! docker inspect -f '{{json .Config.Env}}' web 2>/dev/null | grep -q '"RELEASE=2"'; then
        echo "not yet: web is not running with RELEASE=2. The routine change has to reach it"
        exit 1
      fi

      # replace_plan ADDR: a plan that recreates ADDR, against a copy of the
      # state so nothing the student owns is locked or written.
      cp -a . $G/copy
      replace_plan() {
        (cd $G/copy && tofu plan -input=false -no-color -lock=false -replace="$1" >$G/rp.log 2>&1)
      }

      if replace_plan docker_volume.db_data; then
        echo "not yet: tofu plan -replace=docker_volume.db_data went through: a plan that destroys"
        echo "         the database's volume is still only stopped by someone reading it."
        if grep -qs 'prevent_destroy' ./*.tf; then
          echo "         prevent_destroy is set, but not on docker_volume.db_data: a guard on the"
          echo "         container does not stop the volume under it from being replaced"
        elif grep -qs 'ignore_changes' ./*.tf; then
          echo "         ignore_changes stops OpenTofu from reacting to changes; it does not stop a"
          echo "         replacement or a destroy someone asks for"
        fi
        exit 1
      fi
      if ! grep -q 'prevent_destroy' $G/rp.log; then
        echo "not yet: the plan that replaces db_data failed, but not because of a destroy guard:"
        err $G/rp.log
        exit 1
      fi

      # The colleague's branch, applied to a copy of the code.
      if ! grep -qs '"db-data"' $G/copy/*.tf; then
        echo "not yet: no .tf file names the volume \"db-data\" any more; the volume must keep its name"
        exit 1
      fi
      sed -i 's/"db-data"/"pgdata"/' $G/copy/*.tf
      rc=0
      (cd $G/copy && tofu plan -input=false -no-color -lock=false >$G/rename.log 2>&1) || rc=$?
      if [ "$rc" = 0 ]; then
        echo "not yet: the rename to pgdata still plans cleanly, destroying db-data"
        exit 1
      fi
      if ! grep -q 'prevent_destroy' $G/rename.log; then
        echo "not yet: the rename to pgdata fails to plan, but not because of a destroy guard:"
        err $G/rename.log
        exit 1
      fi
      rm -rf $G/copy
      cp -a . $G/copy

      for a in docker_container.web docker_container.db; do
        if ! replace_plan $a; then
          echo "not yet: tofu plan -replace=$a is blocked:"
          err $G/rp.log
          echo "         Containers hold nothing here; guarding them blocks routine changes such as"
          echo "         a new RELEASE, which recreates web. Guard what holds data, not everything"
          exit 1
        fi
      done
      rm -rf $G

      echo "PASS — any plan that destroys db-data fails before apply, the 200 orders are"
      echo "       intact, and web and db can still be recreated by routine changes."
---
