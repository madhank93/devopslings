---
kind: lesson
title: "move the shop from OpenTofu to Pulumi, and keep the orders"
description: |
  The shop's network, volume and container are managed by OpenTofu, and the
  team is moving to Pulumi. Port the stack to a Go program and hand the
  running resources over, so Pulumi owns all of them, OpenTofu owns none, and
  the orders volume is never recreated.
name: same-infra-in-go
slug: same-infra-in-go
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
      docker network rm shop >/dev/null 2>&1 || true
      docker volume rm shop-orders >/dev/null 2>&1 || true
      rm -rf /root/shop /root/shop-go /var/lib/pulumi/shop
      install -d /root/shop /root/shop-go /var/lib/pulumi/shop /var/lib/devopslings
      cd /root/shop

      cat > main.tf <<'TF'
      terraform {
        required_providers {
          docker = {
            source  = "kreuzwerker/docker"
            version = "4.6.0"
          }
        }
      }

      provider "docker" {}

      resource "docker_network" "shop" {
        name = "shop"
        labels {
          label = "team"
          value = "shop"
        }
      }

      # Holds every order the shop has taken. There is no other copy.
      resource "docker_volume" "orders" {
        name = "shop-orders"
      }

      resource "docker_container" "app" {
        name    = "shop-app"
        image   = "busybox:1.37.0"
        restart = "unless-stopped"
        env     = ["SHOP_ENV=prod"]
        command = ["sh", "-c", "echo shop $SHOP_ENV > /www/index.html; exec httpd -f -p 8080 -h /www"]
        networks_advanced {
          name = docker_network.shop.name
        }
        volumes {
          volume_name    = docker_volume.orders.name
          container_path = "/data"
        }
      }
      TF
      tofu init -input=false >/dev/null
      tofu apply -auto-approve -input=false >/dev/null
      docker exec shop-app sh -c 'for i in $(seq 1 50); do echo "order-$i $(head -c 6 /dev/urandom | od -An -tx1 | tr -d " ")"; done > /data/orders'
      {
        echo "net=$(docker network inspect -f '{{.Id}}' shop)"
        echo "vol=$(docker volume inspect -f '{{.CreatedAt}}' shop-orders | tr ' ' _)"
        echo "sum=$(docker exec shop-app md5sum /data/orders | cut -d' ' -f1)"
      } > /var/lib/devopslings/same-infra-in-go.ids

      cd /root/shop-go
      cp /opt/pulumi-template/go.mod /opt/pulumi-template/go.sum .
      sed -i 's/^module program$/module shop/' go.mod
      cat > Pulumi.yaml <<'YAML'
      name: shop
      runtime: go
      description: the shop, ported from /root/shop
      backend:
        url: file:///var/lib/pulumi/shop
      YAML
      cat > main.go <<'GO'
      package main

      import (
      	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
      )

      func main() {
      	pulumi.Run(func(ctx *pulumi.Context) error {
      		// The shop: the network, volume and container in /root/shop/main.tf.
      		return nil
      	})
      }
      GO
      pulumi stack init dev --non-interactive >/dev/null

      cat > README <<'TXT'
      /root/shop is the shop as OpenTofu describes it, and it is running.
      The team is moving to Pulumi. Port it into /root/shop-go, on the dev stack:

        - the Go program describes the same network, volume and container
        - Pulumi's dev stack owns all three, and OpenTofu's state owns none,
          so a tofu destroy in /root/shop can no longer touch them
        - the shop-orders volume and the shop network are the ones running
          now: not destroyed, not recreated, and the orders still in them
        - pulumi preview shows no changes

      The container holds nothing. The volume holds every order.
      TXT
      echo "scenario ready — /root/shop runs on OpenTofu; port it to /root/shop-go"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      ids=/var/lib/devopslings/same-infra-in-go.ids
      if [ ! -s "$ids" ] || ! cd /root/shop-go 2>/dev/null; then
        echo "not yet: the lesson's files are gone — reset the lesson"
        exit 1
      fi
      want_net=$(sed -n 's/^net=//p' "$ids") want_vol=$(sed -n 's/^vol=//p' "$ids") want_sum=$(sed -n 's/^sum=//p' "$ids")

      # ---- 1. the data, before anything else -----------------------------------
      net=$(docker network inspect -f '{{.Id}}' shop 2>/dev/null || true)
      vol=$(docker volume inspect -f '{{.CreatedAt}}' shop-orders 2>/dev/null | tr ' ' _ || true)
      if [ -z "$vol" ]; then
        echo "not yet: the shop-orders volume is gone, and the orders with it — reset the lesson"
        exit 1
      fi
      if [ "$vol" != "$want_vol" ]; then
        echo "not yet: shop-orders was recreated (created $vol, the original was $want_vol)."
        echo "         The orders in it are gone. Something destroyed it and made a new one —"
        echo "         a tofu destroy, or a pulumi up that created it instead of importing it."
        echo "         Reset the lesson and hand it over without recreating it."
        exit 1
      fi
      sum=$(docker run --rm -v shop-orders:/data busybox:1.37.0 md5sum /data/orders 2>/dev/null | cut -d' ' -f1 || true)
      if [ "$sum" != "$want_sum" ]; then
        echo "not yet: shop-orders is the original volume, but /data/orders in it has changed or is missing"
        exit 1
      fi
      if [ -z "$net" ]; then
        echo "not yet: there is no network called shop"
        exit 1
      elif [ "$net" != "$want_net" ]; then
        echo "not yet: the shop network was recreated (id ${net:0:12}, the original was ${want_net:0:12})."
        echo "         Import it rather than creating a new one"
        exit 1
      fi

      # ---- 2. OpenTofu has let go ------------------------------------------------
      if [ -d /root/shop ]; then
        left=$(cd /root/shop && tofu state list 2>/dev/null || true)
        if [ -n "$left" ]; then
          echo "not yet: OpenTofu's state in /root/shop still holds:"
          sed 's/^/           /' <<<"$left"
          echo "         a tofu destroy there would still delete them. tofu state rm forgets a"
          echo "         resource without touching it"
          exit 1
        fi
      fi

      # ---- 3. Pulumi has taken over ----------------------------------------------
      if ! out=$(go build -o /dev/null . 2>&1); then
        echo "not yet: the program does not build:"
        grep -m3 -E '\.go:[0-9]+' <<<"$out" | sed 's/^/         /' || true
        exit 1
      fi
      st=$(pulumi stack export -s dev --non-interactive 2>/dev/null || true)
      owned() {
        jq -r --arg t "$1" --arg n "$2" '[.deployment.resources[]? | select(.type==$t and .outputs.name==$n) | .id][0] // empty' <<<"$st" 2>/dev/null || true
      }
      pn=$(owned docker:index/network:Network shop)
      pv=$(owned docker:index/volume:Volume shop-orders)
      pc=$(owned docker:index/container:Container shop-app)
      missing=""
      [ -n "$pn" ] || missing="$missing network shop,"
      [ -n "$pv" ] || missing="$missing volume shop-orders,"
      [ -n "$pc" ] || missing="$missing container shop-app,"
      if [ -n "$missing" ]; then
        echo "not yet: the dev stack does not hold:${missing%,}"
        echo "         run pulumi up once the program describes them; pulumi.Import adopts"
        echo "         something that already exists instead of creating it"
        exit 1
      fi
      if [ "$pn" != "$net" ]; then
        echo "not yet: the dev stack tracks network ${pn:0:12}, but shop is ${net:0:12}"
        exit 1
      fi
      live_c=$(docker inspect -f '{{.Id}}' shop-app 2>/dev/null || true)
      if [ "$pc" != "$live_c" ]; then
        echo "not yet: the dev stack tracks shop-app as ${pc:0:12}, but the running one is ${live_c:-nothing}"
        exit 1
      fi
      if grep -qs 'IgnoreChanges' ./*.go; then
        echo "not yet: the program uses IgnoreChanges. That makes the preview quiet by telling"
        echo "         Pulumi to stop comparing, so the code no longer has to match what runs."
        echo "         Describe the resources as they are instead"
        exit 1
      fi

      # ---- 4. the port is faithful -----------------------------------------------
      bad=""
      j=$(docker inspect shop-app)
      [ "$(jq -r '.[0].State.Running' <<<"$j")" = true ] || bad="$bad"$'\n'"shop-app is not running"
      [ "$(jq -r '.[0].HostConfig.RestartPolicy.Name' <<<"$j")" = unless-stopped ] || bad="$bad"$'\n'"shop-app's restart policy is not unless-stopped"
      jq -e '.[0].Config.Env | index("SHOP_ENV=prod")' <<<"$j" >/dev/null || bad="$bad"$'\n'"shop-app has no SHOP_ENV=prod"
      jq -e '.[0].NetworkSettings.Networks | has("shop")' <<<"$j" >/dev/null || bad="$bad"$'\n'"shop-app is not on the shop network"
      jq -e '[.[0].Mounts[] | select(.Name=="shop-orders" and .Destination=="/data")] | length == 1' <<<"$j" >/dev/null \
        || bad="$bad"$'\n'"shop-app does not mount shop-orders at /data"
      [ "$(docker network inspect -f '{{index .Labels "team"}}' shop 2>/dev/null || true)" = shop ] || bad="$bad"$'\n'"the shop network lost its team=shop label"
      body=$(docker exec shop-app wget -qO- -T 3 http://127.0.0.1:8080/ 2>/dev/null || true)
      [ "$body" = "shop prod" ] || bad="$bad"$'\n'"shop-app does not answer 'shop prod' (got: '${body:-nothing}')"
      if [ -n "$bad" ]; then
        echo "not yet: the shop Pulumi runs is not the shop main.tf describes:"
        sed '/^$/d; s/^/           /' <<<"$bad"
        exit 1
      fi
      if ! out=$(pulumi preview -s dev --non-interactive --expect-no-changes --diff 2>&1); then
        echo "not yet: pulumi preview is not clean:"
        grep -E '^ *[-+~]|error:' <<<"$out" | grep -v 'pulumi:pulumi:Stack' | head -8 | sed 's/^/         /' || true
        exit 1
      fi
      echo "PASS — Pulumi owns the shop, OpenTofu owns nothing, and the orders volume and"
      echo "       network are the originals."
---
