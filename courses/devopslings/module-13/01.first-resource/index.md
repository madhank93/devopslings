---
kind: lesson
title: "web runs because someone typed docker run"
description: |
  The web container exists because someone ran run.sh by hand, and the only
  record of how is that script. Describe the container in OpenTofu instead,
  so it can be planned, applied, destroyed and applied again from nothing,
  with the same result every time.
name: first-resource
slug: first-resource
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
      rm -rf /root/web
      install -d /root/web
      cd /root/web

      cat > run.sh <<'SH'
      #!/bin/sh
      # How web gets started. Run by hand after every rebuild of the host.
      docker run -d --name web --restart unless-stopped \
        -e GREETING=hello -e PORT=8080 \
        busybox:1.37.0 \
        sh -c 'echo "$GREETING from web" > /www/index.html; exec httpd -f -p "$PORT" -h /www'
      SH
      chmod +x run.sh

      cat > versions.tf <<'TF'
      terraform {
        required_providers {
          docker = {
            source  = "kreuzwerker/docker"
            version = "4.6.0"
          }
        }
      }

      # Talks to the Docker daemon in DOCKER_HOST, the sandbox's own dind.
      provider "docker" {}
      TF

      cat > README <<'TXT'
      web is started by run.sh, by hand. Replace that with OpenTofu.

        - Describe the container in a .tf file in this directory: the same
          name, image, restart policy, environment and command as run.sh.
        - The running web container must be the one OpenTofu created and
          tracks in its state.
        - plan, apply, destroy and apply again must all work, starting from
          an empty state, and a plan after an apply must show no changes.

      Check it is serving with:  docker exec web wget -qO- http://127.0.0.1:8080/
      TXT

      ./run.sh >/dev/null
      echo "scenario ready — web is running; /root/web/run.sh is how it was started"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      if ! cd /root/web 2>/dev/null; then
        echo "not yet: /root/web is gone — reset the lesson to get it back"
        exit 1
      fi
      if ! grep -qs '^[[:space:]]*resource[[:space:]]*"docker_container"' ./*.tf; then
        echo "not yet: no .tf file in /root/web declares a docker_container resource"
        echo "         run.sh is still the only description of web"
        exit 1
      fi
      if ! out=$(tofu init -input=false -no-color 2>&1); then
        echo "not yet: tofu init fails in /root/web:"
        grep -m3 -E 'Error' <<<"$out" | sed 's/^/         /' || true
        exit 1
      fi
      if ! out=$(tofu validate -no-color 2>&1); then
        echo "not yet: the configuration does not validate:"
        grep -A3 -m1 'Error' <<<"$out" | sed 's/^/         /' || true
        exit 1
      fi

      # state_web: the id of the docker_container named web in state, if any.
      state_web() {
        tofu show -json -no-color 2>/dev/null \
          | jq -r '[.values.root_module.resources[]? | select(.type=="docker_container" and .values.name=="web") | .values.id][0] // empty' || true
      }
      live_web() { docker inspect -f '{{.Id}}' web 2>/dev/null || true; }
      changes() {
        tofu show -json -no-color "$1" | jq -r '.resource_changes[]? | select(.change.actions != ["no-op"]) | "           \(.change.actions | join("/")) \(.address)" + (if (.change.replace_paths // []) == [] then "" else "  (replaced because of: \(.change.replace_paths | map(map(tostring) | join(".")) | join(", ")))" end)' || true
      }
      plan_clean() {
        local rc=0
        tofu plan -input=false -no-color -detailed-exitcode -out=/var/lib/devopslings/first-resource.plan >/var/lib/devopslings/first-resource.log 2>&1 || rc=$?
        if [ "$rc" = 1 ]; then
          echo "not yet: tofu plan fails ($1):"
          grep -A3 -m1 'Error' /var/lib/devopslings/first-resource.log | sed 's/^/         /' || true
          exit 1
        elif [ "$rc" = 2 ]; then
          echo "not yet: $1, a plan still wants changes:"
          local c
          c=$(changes /var/lib/devopslings/first-resource.plan)
          echo "$c"
          if grep -q 'replaced because of: .*env' <<<"$c"; then
            echo "         env forces a replacement: was the container imported? The docker provider"
            echo "         cannot read a container's environment back, so an imported container"
            echo "         always plans one. Remove the hand-made web and let OpenTofu create it"
          else
            echo "         OpenTofu sees a difference between the code, the state and the"
            echo "         running container; tofu plan shows each attribute it would change"
          fi
          exit 1
        fi
      }
      # matches_run_sh: prints what differs between the live web and run.sh.
      matches_run_sh() {
        local j
        j=$(docker inspect web 2>/dev/null) || { echo "there is no container named web"; return; }
        [ "$(jq -r '.[0].State.Running' <<<"$j")" = true ] || echo "web is not running"
        # By ID, so a docker_image resource's image_id counts as busybox too.
        [ "$(jq -r '.[0].Image' <<<"$j")" = "$(docker image inspect -f '{{.Id}}' busybox:1.37.0 2>/dev/null || true)" ] \
          || echo "web runs image $(jq -r '.[0].Config.Image' <<<"$j"), not busybox:1.37.0"
        [ "$(jq -r '.[0].HostConfig.RestartPolicy.Name' <<<"$j")" = unless-stopped ] || echo "web's restart policy is '$(jq -r '.[0].HostConfig.RestartPolicy.Name' <<<"$j")', run.sh uses unless-stopped"
        for e in GREETING=hello PORT=8080; do
          jq -e --arg e "$e" '.[0].Config.Env | index($e)' <<<"$j" >/dev/null || echo "web has no $e in its environment"
        done
        local body
        body=$(docker exec web wget -qO- -T 3 http://127.0.0.1:8080/ 2>/dev/null || true)
        [ "$body" = "hello from web" ] || echo "web does not answer 'hello from web' on port 8080 (got: '${body:-nothing}')"
      }
      need_match() {
        local bad
        bad=$(matches_run_sh)
        if [ -n "$bad" ]; then
          echo "not yet: $1, web is not the container run.sh describes:"
          sed 's/^/           /' <<<"$bad"
          exit 1
        fi
      }

      install -d /var/lib/devopslings
      s=$(state_web) l=$(live_web)
      if [ -z "$s" ]; then
        if [ -n "$l" ]; then
          echo "not yet: a container named web is running, but no docker_container named web is in state"
          echo "         OpenTofu has not created or adopted it, so it is still the hand-made one from run.sh"
        else
          echo "not yet: there is no web container, and none in state — run tofu apply"
        fi
        exit 1
      fi
      if [ -z "$l" ]; then
        echo "not yet: state tracks web as container ${s:0:12}, but no container named web exists"
        echo "         run tofu plan to see what OpenTofu thinks happened"
        exit 1
      elif [ "$s" != "$l" ]; then
        echo "not yet: state tracks web as container ${s:0:12}, but the web that is running is ${l:0:12}"
        echo "         the running one was not created by this configuration"
        exit 1
      fi
      # destroy removes a docker_image's image from the daemon unless keep_locally
      # is set, and the sandbox's busybox has no registry copy to pull back.
      if tofu show -json -no-color 2>/dev/null \
        | jq -e '[.values.root_module.resources[]? | select(.type=="docker_image" and .values.keep_locally != true)] | length > 0' >/dev/null; then
        echo "not yet: a docker_image resource without keep_locally = true deletes busybox:1.37.0"
        echo "         from the daemon on every tofu destroy, and this sandbox's busybox is not"
        echo "         in any registry. Set keep_locally = true, or give docker_container the"
        echo "         image name directly. If you already destroyed it, reset the lesson"
        exit 1
      fi
      need_match "as it runs now"
      plan_clean "on the running container"

      # The cycle the README asks for. It ends where it started: web applied
      # from code, so a second run of this check sees the same thing.
      if ! out=$(tofu destroy -auto-approve -input=false -no-color 2>&1); then
        echo "not yet: tofu destroy fails:"
        grep -A3 -m1 'Error' <<<"$out" | sed 's/^/         /' || true
        exit 1
      fi
      if [ -n "$(live_web)" ]; then
        echo "not yet: after tofu destroy a container named web is still there"
        echo "         something outside the docker_container resource started it"
        exit 1
      fi
      left=$(tofu state list 2>/dev/null || true)
      if [ -n "$left" ]; then
        echo "not yet: after tofu destroy, state still holds:"
        sed 's/^/           /' <<<"$left"
        exit 1
      fi
      if ! out=$(tofu apply -auto-approve -input=false -no-color 2>&1); then
        echo "not yet: tofu apply from an empty state fails:"
        grep -A3 -m1 'Error' <<<"$out" | sed 's/^/         /' || true
        exit 1
      fi
      need_match "after destroy and a fresh apply"
      plan_clean "after destroy and a fresh apply"
      rm -f /var/lib/devopslings/first-resource.plan /var/lib/devopslings/first-resource.log

      echo "PASS — web is created from code, matches run.sh, and survives destroy and"
      echo "       apply from an empty state with a clean plan each time."
---
