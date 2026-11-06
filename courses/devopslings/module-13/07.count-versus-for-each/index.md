---
kind: lesson
title: "retire billing, and the plan recreates search"
description: |
  Three services are created from a list with count. Billing is being
  retired, but taking it out of the list makes the plan rebuild search and
  destroy the wrong container. Retire billing so that only billing is
  touched, and so that the next change to the list touches only what changed.
name: count-versus-for-each
slug: count-versus-for-each
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
      rm -rf /root/svc
      install -d /root/svc /var/lib/devopslings
      cd /root/svc

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

      cat > variables.tf <<'TF'
      variable "services" {
        description = "Names of the services to run, one container each."
        type        = list(string)
      }
      TF

      cat > terraform.tfvars <<'TF'
      services = ["auth", "billing", "search"]
      TF

      cat > main.tf <<'TF'
      resource "docker_container" "svc" {
        count = length(var.services)

        name    = "svc-${var.services[count.index]}"
        image   = "busybox:1.37.0"
        restart = "unless-stopped"
        command = ["sh", "-c", "echo ${var.services[count.index]} > /www/index.html; exec httpd -f -p 8080 -h /www"]
      }
      TF

      cat > README <<'TXT'
      billing is being retired. Take it out of terraform.tfvars and apply.

        - svc-billing must be destroyed.
        - svc-auth and svc-search must not be touched: the same containers
          must keep running.
        - After the next edit to the list, a plan must touch only the item
          that was added or removed, wherever in the list it was.

      Keep variable "services" as a list of names: other configurations pass
      it in that form.
      TXT

      tofu init -input=false >/dev/null
      tofu apply -auto-approve -input=false >/dev/null
      {
        echo "auth=$(docker inspect -f '{{.Id}}' svc-auth)"
        echo "search=$(docker inspect -f '{{.Id}}' svc-search)"
      } > /var/lib/devopslings/count-versus-for-each.env
      echo "scenario ready — remove billing from /root/svc/terraform.tfvars and read the plan before you apply"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      if ! cd /root/svc 2>/dev/null || [ ! -f /var/lib/devopslings/count-versus-for-each.env ]; then
        echo "not yet: /root/svc is gone — reset the lesson to get it back"
        exit 1
      fi
      . /var/lib/devopslings/count-versus-for-each.env
      G=/var/lib/devopslings/count-versus-for-each
      install -d $G
      err() { grep -A3 -m1 'Error' "$1" | sed 's/^/         /' || true; }

      # The containers first: a wrong apply cannot be undone by fixing code.
      now_auth=$(docker inspect -f '{{.Id}}' svc-auth 2>/dev/null || true)
      now_search=$(docker inspect -f '{{.Id}}' svc-search 2>/dev/null || true)
      for n in auth search; do
        was=${!n} now=now_$n
        if [ "${!now}" != "$was" ]; then
          if [ -z "${!now}" ]; then
            echo "not yet: svc-$n is gone. It was supposed to keep running."
          else
            echo "not yet: svc-$n was destroyed and recreated. It was supposed to be left alone."
          fi
          if ! grep -qsE '\bfor_each\b' ./*.tf; then
            echo "         With count, each container is known by its position. Removing billing"
            echo "         shifts search from svc[2] to svc[1], so svc[2], the real search, is the one"
            echo "         that gets destroyed, and svc[1] becomes the new search."
          else
            echo "         Switching to for_each changes every address, from svc[0] to svc[\"auth\"]."
            echo "         Unless OpenTofu is told which old address is which new one, it destroys"
            echo "         the old object and creates a new one. The old positions were"
            echo "         svc[0] auth, svc[1] billing, svc[2] search."
          fi
          echo "         Reset the lesson to get the original containers back."
          exit 1
        fi
      done
      if docker inspect svc-billing >/dev/null 2>&1; then
        echo "not yet: svc-billing is still running; billing is being retired"
        exit 1
      fi

      if ! tofu init -input=false -no-color >$G/init.log 2>&1; then
        echo "not yet: tofu init fails:"
        err $G/init.log
        exit 1
      fi
      # plan_with ARGS: plans to $G/plan, leaving exit code in $prc.
      plan_with() {
        prc=0
        tofu plan -input=false -no-color -detailed-exitcode -out=$G/plan "$@" >$G/plan.log 2>&1 || prc=$?
        if [ "$prc" = 1 ]; then
          echo "not yet: tofu plan $* fails:"
          err $G/plan.log
          exit 1
        fi
      }
      changes() {
        tofu show -json -no-color $G/plan | jq -r '.resource_changes[]? | select(.change.actions != ["no-op"]) | "           \(.change.actions | join("/")) \(.address) (\(.change.before.name // .change.after.name))"' || true
      }

      plan_with
      pj=$(tofu show -json -no-color $G/plan)
      if jq -e '.variables.services.value | index("billing")' <<<"$pj" >/dev/null 2>&1; then
        echo "not yet: billing is still in var.services (terraform.tfvars); retiring it means taking it out"
        exit 1
      fi
      if [ "$prc" = 2 ]; then
        echo "not yet: the plan for the current code is not clean:"
        changes
        exit 1
      fi
      live=$(docker ps --format '{{.Names}}' | grep '^svc-' | sort | tr '\n' ' ' || true)
      if [ "$live" != "svc-auth svc-search " ]; then
        echo "not yet: running services are: ${live:-none}; expected svc-auth and svc-search"
        exit 1
      fi
      dc=$(jq -c '[.configuration.root_module.resources[]? | select(.type=="docker_container")]' <<<"$pj")
      if [ "$(jq length <<<"$dc")" != 1 ]; then
        echo "not yet: the code has $(jq length <<<"$dc") docker_container blocks. Keep one, driven by var.services;"
        echo "         a block per service has to be edited by hand every time the list changes"
        exit 1
      fi
      if jq -e '.[0] | has("count_expression")' <<<"$dc" >/dev/null; then
        echo "not yet: billing is gone and the others survived, but the resource still uses count."
        echo "         The next removal from the middle of the list will rebuild its neighbours again"
        exit 1
      fi

      # The next change to the list, wherever it lands, touches one item.
      for t in 'services=["search"]|removing auth from the front|delete|svc-auth' \
               'services=["auth"]|removing search from the end|delete|svc-search' \
               'services=["api", "auth", "search"]|adding api at the front|create|svc-api'; do
        IFS='|' read -r var what act name <<<"$t"
        plan_with -var "$var"
        got=$(tofu show -json -no-color $G/plan | jq -c '[.resource_changes[]? | select(.change.actions != ["no-op"]) | {a: (.change.actions | join("/")), n: (.change.before.name // .change.after.name)}]')
        if [ "$got" != "[{\"a\":\"$act\",\"n\":\"$name\"}]" ]; then
          echo "not yet: the grader planned $what (-var '$var'). It should $act $name"
          echo "         and touch nothing else, but the plan wants:"
          changes
          exit 1
        fi
      done
      rm -rf $G

      echo "PASS — billing is retired, auth and search are the original containers, and"
      echo "       adding or removing any item from the list touches only that item."
---
