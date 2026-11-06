---
kind: lesson
title: "a rename in the code, and the plan wants to destroy production"
description: |
  A tidy-up commit renamed a resource and handed another container to a
  different team. Nothing real changed, but the plan now wants to destroy and
  recreate api and destroy the platform team's job. Make the plan empty
  without recreating anything, and without opening the state file in an
  editor.
name: what-is-in-state
slug: what-is-in-state
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
      rm -rf /root/app
      install -d /root/app /var/lib/devopslings
      cd /root/app
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
      printf '.terraform/\n*.tfstate\n*.tfstate.*\n' > .gitignore

      cat > main.tf <<'TF'
      resource "docker_container" "app" {
        name    = "api"
        image   = "busybox:1.37.0"
        restart = "unless-stopped"
        command = ["sh", "-c", "echo 'api v2' > /www/index.html; exec httpd -f -p 8080 -h /www"]
      }

      resource "docker_container" "legacy" {
        name    = "nightly-report"
        image   = "busybox:1.37.0"
        restart = "unless-stopped"
        command = ["sh", "-c", "while true; do sleep 3600; done"]
      }
      TF
      git add -A && git commit -qm "api and the nightly report"
      tofu init -input=false >/dev/null
      tofu apply -auto-approve -input=false >/dev/null

      cat > main.tf <<'TF'
      resource "docker_container" "api" {
        name    = "api"
        image   = "busybox:1.37.0"
        restart = "unless-stopped"
        command = ["sh", "-c", "echo 'api v2' > /www/index.html; exec httpd -f -p 8080 -h /www"]
      }
      TF
      git add -A && git commit -qm "Name the resource after the service; nightly-report moves to the platform repo

      The platform team now owns nightly-report and manages it from their own
      configuration. It keeps running; it is just not ours any more."

      cat > README <<'TXT'
      The last commit (git show) is correct and stays as it is:

        - docker_container.app is now called docker_container.api
        - nightly-report is no longer managed here. The platform team owns
          it now. It must keep running.

      tofu plan now wants to destroy and recreate api, and destroy
      nightly-report. Neither may happen. Get to an empty plan with both
      containers untouched, without undoing the commit. Do not edit
      terraform.tfstate by hand.
      TXT

      {
        echo "api=$(docker inspect -f '{{.Id}}' api)"
        echo "cron=$(docker inspect -f '{{.Id}}' nightly-report)"
        echo "serial=$(jq -r .serial terraform.tfstate)"
        echo "lineage=$(jq -r .lineage terraform.tfstate)"
        echo "addrs=$(jq -r '[.resources[] | "\(.type).\(.name)"] | sort | join(",")' terraform.tfstate)"
      } > /var/lib/devopslings/what-is-in-state.env
      echo "scenario ready — run tofu plan in /root/app and read what it wants to do"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      if ! cd /root/app 2>/dev/null || [ ! -f /var/lib/devopslings/what-is-in-state.env ]; then
        echo "not yet: /root/app is gone — reset the lesson to get it back"
        exit 1
      fi
      . /var/lib/devopslings/what-is-in-state.env
      st=terraform.tfstate

      if [ ! -f $st ]; then
        echo "not yet: terraform.tfstate is gone. It was the only record of which containers"
        echo "         this configuration owns. terraform.tfstate.backup holds the previous version"
        exit 1
      fi
      if ! jq -e . $st >/dev/null 2>&1; then
        echo "not yet: terraform.tfstate is not valid JSON any more, so OpenTofu cannot read it"
        echo "         restore terraform.tfstate.backup, or reset the lesson"
        exit 1
      fi

      # The containers must be the ones init created, untouched.
      now_api=$(docker inspect -f '{{.Id}}' api 2>/dev/null || true)
      now_cron=$(docker inspect -f '{{.Id}}' nightly-report 2>/dev/null || true)
      if [ "$now_cron" != "$cron" ]; then
        if [ -z "$now_cron" ]; then
          echo "not yet: nightly-report is gone. Removing it from the code told OpenTofu to destroy it."
        else
          echo "not yet: nightly-report was destroyed and recreated (it is a different container now)."
        fi
        echo "         It belongs to the platform team and had to keep running. OpenTofu has to"
        echo "         forget it, not destroy it. Reset the lesson to get the original back."
        exit 1
      fi
      if [ "$now_api" != "$api" ]; then
        echo "not yet: api was ${now_api:+destroyed and }recreated${now_api:- and is not running}: that is the outage this lesson"
        echo "         avoids. Only the address in the code changed, so only the address in state"
        echo "         should change. Reset the lesson to get the original back."
        exit 1
      fi

      # Hand edits skip the bookkeeping OpenTofu does on every write.
      cur_lineage=$(jq -r .lineage $st) cur_serial=$(jq -r .serial $st)
      cur_addrs=$(jq -r '[.resources[] | "\(.type).\(.name)"] | sort | join(",")' $st)
      if [ "$cur_lineage" != "$lineage" ]; then
        echo "not yet: terraform.tfstate has a different lineage than the state that built these"
        echo "         containers, so it was replaced rather than changed. Reset the lesson"
        exit 1
      fi
      if [ "$cur_addrs" != "$addrs" ] && [ "$cur_serial" -le "$serial" ]; then
        echo "not yet: the resources in terraform.tfstate changed ($addrs -> ${cur_addrs:-none})"
        echo "         but its serial is still $cur_serial. OpenTofu bumps the serial on every write,"
        echo "         and a remote backend uses it to refuse stale writes; this was edited by hand."
        echo "         Restore terraform.tfstate.backup or reset, then use tofu state commands"
        exit 1
      fi

      # Every state write by OpenTofu leaves the version before it as a backup.
      if [ "$cur_addrs" != "$addrs" ]; then
        older=""
        for b in terraform.tfstate*.backup; do
          [ -f "$b" ] || continue
          if jq -e --arg l "$lineage" --argjson s "$cur_serial" '.lineage == $l and .serial < $s' "$b" >/dev/null 2>&1; then
            older=$b
          fi
        done
        if [ -z "$older" ]; then
          echo "not yet: terraform.tfstate changed, but no backup of an earlier version sits next to it."
          echo "         tofu state mv, state rm and apply each write one when they change state;"
          echo "         an edit by hand does not. Reset the lesson and use tofu state commands"
          exit 1
        fi
      fi

      # A hand edit laundered by a later apply survives in the backup that
      # apply wrote: a state with the original serial but different contents.
      for b in terraform.tfstate*.backup; do
        [ -f "$b" ] || continue
        b_info=$(jq -r '"\(.lineage) \(.serial) \([.resources[] | "\(.type).\(.name)"] | sort | join(","))"' "$b" 2>/dev/null || true)
        if [ "$b_info" != "" ] && [ "${b_info% *}" = "$lineage $serial" ] && [ "${b_info##* }" != "$addrs" ]; then
          echo "not yet: $b is a state with serial $serial, the serial init left, but it holds"
          echo "         ${b_info##* } instead of $addrs. OpenTofu never writes two different"
          echo "         states with one serial, so that one was edited by hand and then applied over."
          echo "         Reset the lesson and use tofu state commands"
          exit 1
        fi
      done

      if ! out=$(tofu init -input=false -no-color 2>&1); then
        echo "not yet: tofu init fails:"
        grep -A3 -m1 'Error' <<<"$out" | sed 's/^/         /' || true
        exit 1
      fi
      plan=/var/lib/devopslings/what-is-in-state.plan
      rc=0
      out=$(tofu plan -input=false -no-color -detailed-exitcode -out=$plan 2>&1) || rc=$?
      if [ "$rc" = 1 ]; then
        echo "not yet: tofu plan fails:"
        grep -A3 -m1 'Error' <<<"$out" | sed 's/^/         /' || true
        exit 1
      fi
      pj=$(tofu show -json -no-color $plan)
      cfg=$(jq -r '[.configuration.root_module.resources[]? | .address] | sort | join(",")' <<<"$pj")
      if [ "$cfg" != docker_container.api ]; then
        echo "not yet: the code now declares: ${cfg:-no resources}"
        echo "         the last commit is correct as it is: one resource, docker_container.api."
        echo "         Fix what the state records instead (git diff HEAD shows your changes)"
        exit 1
      fi
      if [ "$rc" = 2 ]; then
        echo "not yet: tofu plan still wants changes:"
        jq -r '.resource_changes[]? | select(.change.actions != ["no-op"]) | "           \(.change.actions | join("/")) \(.address)" + (if (.change.replace_paths // []) == [] then "" else "  (replaced because of: \(.change.replace_paths | map(map(tostring) | join(".")) | join(", ")))" end)' <<<"$pj" || true
        acts=$(jq -r '.resource_changes[]? | select(.change.actions != ["no-op"]) | "\(.change.actions | join("/")) \(.address)"' <<<"$pj" || true)
        if grep -q '^create docker_container.api' <<<"$acts"; then
          echo "         state records the api container under the old address docker_container.app,"
          echo "         so OpenTofu thinks .api is new and .app was deleted from the code"
        fi
        if grep -q '^delete docker_container.legacy' <<<"$acts"; then
          echo "         state still says this configuration owns nightly-report, and the code no"
          echo "         longer mentions it, so OpenTofu plans to destroy it"
        fi
        if jq -e '[.resource_changes[]? | (.change.replace_paths // [])[] | .[0]] | index("env")' <<<"$pj" >/dev/null 2>&1; then
          echo "         env forces a replacement: was the container imported? The docker provider"
          echo "         cannot read a container's environment back, so an imported container always"
          echo "         plans one. The original record, written by the apply that built it, does not"
        fi
        if grep -q '^forget ' <<<"$acts"; then
          echo "         a removed block is waiting to be applied: tofu apply makes it real"
        fi
        exit 1
      fi
      sid=$(jq -r '[.prior_state.values.root_module.resources[]? | select(.address=="docker_container.api") | .values.id][0] // empty' <<<"$pj")
      if [ "$sid" != "$api" ]; then
        echo "not yet: state's docker_container.api is not the running api container"
        exit 1
      fi
      rm -f $plan

      echo "PASS — the plan is empty, api and nightly-report are the original containers,"
      echo "       and the state changed through OpenTofu, not an editor."
---
