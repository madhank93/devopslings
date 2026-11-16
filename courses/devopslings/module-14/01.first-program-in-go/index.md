---
kind: lesson
title: "web in Go, and the compiler has an opinion"
description: |
  web is described in a Pulumi program written in Go, and the program does
  not build. Fix it, take web through up, destroy and up again, and record
  which mistake the compiler caught, which one it could not, and when
  OpenTofu would have caught the same thing.
name: first-program-in-go
slug: first-program-in-go
createdAt: "2026-11-13"

sandbox:
  stack: iac-stack
  service: ws

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      docker rm -f $(docker ps -aq) >/dev/null 2>&1 || true
      rm -rf /root/hello /var/lib/pulumi/hello
      install -d /root/hello/hcl /var/lib/pulumi/hello
      cd /root/hello

      cp /opt/pulumi-template/go.mod /opt/pulumi-template/go.sum .
      sed -i 's/^module program$/module hello/' go.mod

      cat > Pulumi.yaml <<'YAML'
      name: hello
      runtime: go
      description: web, the container run.sh used to start by hand
      # State is kept on local disk, so no Pulumi Cloud account is involved.
      backend:
        url: file:///var/lib/pulumi/hello
      YAML

      cat > main.go <<'GO'
      package main

      import (
      	"github.com/pulumi/pulumi-docker/sdk/v5/go/docker"
      	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
      )

      func main() {
      	pulumi.Run(func(ctx *pulumi.Context) error {
      		_, err := docker.NewContainer(ctx, "web", &docker.ContainerArgs{
      			Name:    pulumi.String("web"),
      			Image:   pulumi.String("busybox:1.37.0"),
      			Restart: pulumi.String("unless-stoped"),
      			Envs:    pulumi.String("GREETING=hello PORT=8080"),
      			Command: pulumi.ToStringArray([]string{
      				"sh", "-c",
      				`echo "$GREETING from web" > /www/index.html; exec httpd -f -p "$PORT" -h /www`,
      			}),
      		})
      		return err
      	})
      }
      GO

      cat > hcl/versions.tf <<'TF'
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

      # The same environment mistake as main.go, in HCL. Nothing applies this;
      # it is here to find out when OpenTofu notices.
      cat > hcl/main.tf <<'TF'
      resource "docker_container" "web" {
        name    = "web-hcl"
        image   = "busybox:1.37.0"
        restart = "unless-stopped"
        env     = "GREETING=hello PORT=8080"
        command = ["sh", "-c", "echo \"$GREETING from web\" > /www/index.html; exec httpd -f -p \"$PORT\" -h /www"]
      }
      TF

      cat > answers.txt <<'ANS'
      # Replace every ? with your answer.
      #
      # compiler=  the ContainerArgs field that go build rejects
      # preview=   the field go build accepts and pulumi preview rejects
      # tofu=      init | validate | plan | apply: the first tofu command that
      #            rejects hcl/main.tf, which makes main.go's first mistake in HCL

      compiler=?
      preview=?
      tofu=?
      ANS

      cat > README <<'TXT'
      main.go describes web, the same container module 13 started with:

        docker run -d --name web --restart unless-stopped \
          -e GREETING=hello -e PORT=8080 busybox:1.37.0 \
          sh -c 'echo "$GREETING from web" > /www/index.html; exec httpd -f -p "$PORT" -h /www'

      It does not build. Make it build and deploy, on the stack called dev:

        - web runs as that docker run line describes, created by pulumi up
        - pulumi destroy removes it, and pulumi up brings it back
        - pulumi preview after an up shows no changes

      Then fill in answers.txt. hcl/ holds the HCL version of main.go's
      first mistake. Run tofu in there to find out when OpenTofu notices it.

      Check it is serving with:  docker exec web wget -qO- http://127.0.0.1:8080/
      TXT

      pulumi stack init dev --non-interactive >/dev/null
      echo "scenario ready — /root/hello/main.go does not build yet"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      if ! cd /root/hello 2>/dev/null; then
        echo "not yet: /root/hello is gone — reset the lesson to get it back"
        exit 1
      fi
      p() { local c=$1; shift; pulumi --non-interactive "$c" -s dev "$@"; }
      if ! out=$(go build -o /dev/null . 2>&1); then
        echo "not yet: the program does not build:"
        grep -m3 -E '\.go:[0-9]+' <<<"$out" | sed 's/^/         /' || true
        exit 1
      fi
      if ! p stack ls >/dev/null 2>&1; then
        echo "not yet: pulumi cannot read the dev stack — reset the lesson to recreate it"
        exit 1
      fi

      state_web() {
        p stack export 2>/dev/null \
          | jq -r '[.deployment.resources[]? | select(.type=="docker:index/container:Container" and .outputs.name=="web") | .id][0] // empty' || true
      }
      live_web() { docker inspect -f '{{.Id}}' web 2>/dev/null || true; }
      # mismatch: prints what differs between the live web and the docker run line.
      mismatch() {
        local j
        j=$(docker inspect web 2>/dev/null) || { echo "there is no container named web"; return; }
        [ "$(jq -r '.[0].State.Running' <<<"$j")" = true ] || echo "web is not running"
        [ "$(jq -r '.[0].Image' <<<"$j")" = "$(docker image inspect -f '{{.Id}}' busybox:1.37.0 2>/dev/null || true)" ] \
          || echo "web runs image $(jq -r '.[0].Config.Image' <<<"$j"), not busybox:1.37.0"
        local r
        r=$(jq -r '.[0].HostConfig.RestartPolicy.Name' <<<"$j")
        [ "$r" = unless-stopped ] || echo "web's restart policy is '$r', the docker run line uses unless-stopped"
        for e in GREETING=hello PORT=8080; do
          jq -e --arg e "$e" '.[0].Config.Env | index($e)' <<<"$j" >/dev/null \
            || echo "web has no $e in its environment (it has: $(jq -r '.[0].Config.Env // [] | join(" | ")' <<<"$j"))"
        done
        local body
        body=$(docker exec web wget -qO- -T 3 http://127.0.0.1:8080/ 2>/dev/null || true)
        [ "$body" = "hello from web" ] || echo "web does not answer 'hello from web' on port 8080 (got: '${body:-nothing}')"
      }
      need_match() {
        local bad
        bad=$(mismatch)
        if [ -n "$bad" ]; then
          echo "not yet: $1, web is not the container the docker run line describes:"
          sed 's/^/           /' <<<"$bad"
          exit 1
        fi
      }
      preview_clean() {
        local out
        if ! out=$(p preview --expect-no-changes --diff 2>&1); then
          echo "not yet: $1, pulumi preview does not come back clean:"
          grep -E '^ *[-+~]|error:' <<<"$out" | grep -v 'pulumi:pulumi:Stack' | head -8 | sed 's/^/         /' || true
          exit 1
        fi
      }

      s=$(state_web) l=$(live_web)
      if [ -z "$s" ]; then
        if [ -n "$l" ]; then
          echo "not yet: a container named web is running, but the dev stack's state has no web"
          echo "         Pulumi did not create it; run pulumi up and let it"
        else
          echo "not yet: there is no web container, and none in the dev stack — run pulumi up"
        fi
        exit 1
      fi
      if [ -z "$l" ]; then
        echo "not yet: the dev stack tracks web as container ${s:0:12}, but no container named web exists"
        echo "         run pulumi preview --refresh to see what Pulumi makes of that"
        exit 1
      elif [ "$s" != "$l" ]; then
        echo "not yet: the dev stack tracks web as ${s:0:12}, but the web that is running is ${l:0:12}"
        exit 1
      fi
      need_match "as it runs now"
      preview_clean "on the running container"

      ans=answers.txt
      get() { sed -n "s/^$1=[[:space:]]*\([A-Za-z?]*\).*/\1/p" "$ans" 2>/dev/null | head -1 | tr 'A-Z' 'a-z'; }
      c=$(get compiler) v=$(get preview) t=$(get tofu)
      if [ -z "$c$v$t" ] || [ "$c" = "?" ] || [ "$v" = "?" ] || [ "$t" = "?" ] || [ -z "$c" ] || [ -z "$v" ] || [ -z "$t" ]; then
        echo "not yet: web is deployed; now fill in compiler=, preview= and tofu= in /root/hello/answers.txt"
        exit 1
      fi
      if [ "$c" != envs ]; then
        echo "not yet: compiler=$c. go build names the field on the line it rejects;"
        echo "         put the original mistake back for a moment and read the message"
        exit 1
      fi
      if [ "$v" != restart ]; then
        echo "not yet: preview=$v. Which field held a value of the right type and the wrong"
        echo "         content? The compiler checks types; the provider checks values"
        exit 1
      fi
      case "$t" in
        validate) ;;
        apply|plan) echo "not yet: tofu=$t. Try it: cd hcl && tofu init && tofu validate"
                    exit 1 ;;
        init) echo "not yet: tofu=init. tofu init only installs providers; run it in hcl/ and see"
              exit 1 ;;
        *) echo "not yet: tofu=$t, which is not one of init, validate, plan, apply"
           exit 1 ;;
      esac

      # The cycle the README asks for. It ends with web applied, so a second
      # run of this check starts from the same place.
      if ! out=$(p destroy --yes 2>&1); then
        echo "not yet: pulumi destroy fails:"
        grep -m3 'error:' <<<"$out" | sed 's/^/         /' || true
        exit 1
      fi
      if [ -n "$(live_web)" ]; then
        echo "not yet: after pulumi destroy a container named web is still there"
        echo "         is the resource marked retainOnDelete, or did something else start it?"
        exit 1
      fi
      if [ -n "$(state_web)" ]; then
        echo "not yet: after pulumi destroy the dev stack still holds web"
        exit 1
      fi
      if ! out=$(p up --yes 2>&1); then
        echo "not yet: pulumi up from an empty stack fails:"
        grep -m3 'error:' <<<"$out" | sed 's/^/         /' || true
        exit 1
      fi
      need_match "after destroy and a fresh up"
      preview_clean "after destroy and a fresh up"

      echo "PASS — web is built from Go, survives destroy and up with a clean preview,"
      echo "       and the answers say which layer caught which mistake."
---
