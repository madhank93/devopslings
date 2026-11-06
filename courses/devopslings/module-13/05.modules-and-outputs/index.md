---
kind: lesson
title: "the same three resources, pasted four times"
description: |
  Every environment of the shop is a network, a volume and a container,
  copied block by block four times, and the copies have already started to
  drift. Turn them into one module used four times, without recreating
  anything that is running and without breaking the output the deploy
  script reads.
name: modules-and-outputs
slug: modules-and-outputs
createdAt: "2026-10-15"

sandbox:
  stack: iac-stack
  service: ws

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      docker rm -f $(docker ps -aq) >/dev/null 2>&1 || true
      for e in dev test staging prod; do
        docker network rm shop-$e >/dev/null 2>&1 || true
        docker volume rm shop-$e-data >/dev/null 2>&1 || true
      done
      rm -rf /root/envs
      install -d /root/envs /var/lib/devopslings
      cd /root/envs

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

      # prod was hand-tuned to restart always; the other copies were not.
      for e in dev test staging prod; do
        r=unless-stopped
        [ $e = prod ] && r=always
        cat <<TF
      # ---- $e ------------------------------------------------------------
      resource "docker_network" "${e}_net" {
        name = "shop-$e"
      }

      resource "docker_volume" "${e}_data" {
        name = "shop-$e-data"
      }

      resource "docker_container" "${e}_app" {
        name    = "shop-$e"
        image   = "busybox:1.37.0"
        restart = "$r"
        env     = ["SHOP_ENV=$e"]
        command = ["sh", "-c", "echo shop \$SHOP_ENV > /www/index.html; exec httpd -f -p 8080 -h /www"]
        networks_advanced {
          name = docker_network.${e}_net.name
        }
        volumes {
          volume_name    = docker_volume.${e}_data.name
          container_path = "/data"
        }
      }

      TF
      done > main.tf

      cat > outputs.tf <<'TF'
      # deploy.sh reads this to find each environment's endpoint.
      output "endpoints" {
        value = {
          dev     = "http://${docker_container.dev_app.name}:8080"
          test    = "http://${docker_container.test_app.name}:8080"
          staging = "http://${docker_container.staging_app.name}:8080"
          prod    = "http://${docker_container.prod_app.name}:8080"
        }
      }
      TF

      cat > README <<'TXT'
      main.tf is one environment's network, volume and container, pasted
      four times: dev, test, staging and prod. A fifth is on the way.

      Replace the copies with one module, used once per environment:

        - one module directory under modules/, holding one docker_network,
          one docker_volume and one docker_container
        - no docker_* resource blocks left in the root configuration
        - the running networks, volumes and containers stay exactly as they
          are: nothing is destroyed or recreated, and every environment keeps
          its settings (look closely at prod)
        - tofu output -json endpoints gives deploy.sh the same map as now
        - tofu plan shows no changes
      TXT

      tofu init -input=false >/dev/null
      tofu apply -auto-approve -input=false >/dev/null
      for e in dev test staging prod; do
        docker exec shop-$e sh -c "echo $e-orders > /data/orders"
        echo "$e=$(docker inspect -f '{{.Id}}' shop-$e) $(docker network inspect -f '{{.Id}}' shop-$e) $(docker volume inspect -f '{{.CreatedAt}}' shop-$e-data | tr ' ' _)"
      done > /var/lib/devopslings/modules-and-outputs.ids
      tofu output -json endpoints > /var/lib/devopslings/modules-and-outputs.endpoints
      echo "scenario ready — /root/envs: four copies of the same three resources"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      if ! cd /root/envs 2>/dev/null || [ ! -f /var/lib/devopslings/modules-and-outputs.ids ]; then
        echo "not yet: /root/envs is gone — reset the lesson to get it back"
        exit 1
      fi
      G=/var/lib/devopslings/modules-and-outputs
      rm -rf $G
      install -d $G
      err() { grep -A3 -m1 'Error' "$1" | sed 's/^/         /' || true; }

      # What is running first: a wrong apply cannot be undone by fixing code.
      while read -r line; do
        e=${line%%=*}
        set -- ${line#*=}
        c=$(docker inspect -f '{{.Id}}' shop-$e 2>/dev/null || true)
        n=$(docker network inspect -f '{{.Id}}' shop-$e 2>/dev/null || true)
        v=$(docker volume inspect -f '{{.CreatedAt}}' shop-$e-data 2>/dev/null | tr ' ' _ || true)
        for p in "container shop-$e|$c|$1" "network shop-$e|$n|$2" "volume shop-$e-data|$v|$3"; do
          IFS='|' read -r what now was <<<"$p"
          if [ "$now" != "$was" ]; then
            echo "not yet: the $what is ${now:+not the original: it was destroyed and recreated}${now:-gone}."
            echo "         Moving a resource into a module changes its address, from"
            echo "         docker_container.${e}_app to something like module.shop[\"$e\"].docker_container.app."
            echo "         OpenTofu matches by address, so unless it is told the two are the same"
            echo "         object (a moved block, or tofu state mv), it destroys one and creates the"
            echo "         other. Reset the lesson to get the originals back"
            exit 1
          fi
        done
        if [ "$(docker exec shop-$e cat /data/orders 2>/dev/null || true)" != "$e-orders" ]; then
          echo "not yet: shop-$e no longer sees /data/orders from shop-$e-data; the volume mount changed"
          exit 1
        fi
        want=unless-stopped
        [ $e = prod ] && want=always
        got=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' shop-$e)
        if [ "$got" != "$want" ]; then
          echo "not yet: shop-$e now restarts '$got'; it was '$want'."
          echo "         The four copies were not identical. A module that hard-codes one copy's"
          echo "         values flattens the difference; make it an input"
          exit 1
        fi
        if ! docker inspect -f '{{json .Config.Env}}' shop-$e | grep -q "\"SHOP_ENV=$e\""; then
          echo "not yet: shop-$e lost SHOP_ENV=$e from its environment"
          exit 1
        fi
      done < /var/lib/devopslings/modules-and-outputs.ids

      if ! tofu init -input=false -no-color >$G/init.log 2>&1; then
        echo "not yet: tofu init fails:"
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

      root=$(jq -r '[.configuration.root_module.resources[]? | select(.mode=="managed") | .address] | if length > 3 then (.[:3] + ["and \(length - 3) more"]) else . end | join(", ")' <<<"$pj")
      if [ -n "$root" ]; then
        echo "not yet: the root configuration still declares $root"
        echo "         Every environment's resources belong in the module"
        exit 1
      fi
      calls=$(jq -c '[.configuration.root_module.module_calls // {} | to_entries[] | {name: .key, source: .value.source, types: [.value.module.resources[]? | .type]}]' <<<"$pj")
      if [ "$(jq length <<<"$calls")" = 0 ]; then
        echo "not yet: the root configuration calls no module"
        exit 1
      fi
      srcs=$(jq -r '[.[].source] | unique | join(" ")' <<<"$calls")
      if [ "$(jq '[.[].source] | unique | length' <<<"$calls")" != 1 ]; then
        echo "not yet: the module blocks use more than one source ($srcs)."
        echo "         One module, used four times: a copy per environment is the same paste"
        echo "         in a different directory"
        exit 1
      fi
      case $srcs in
        ./modules/*|modules/*) ;;
        *)
          echo "not yet: the module source is $srcs; the README asks for a directory under modules/"
          exit 1 ;;
      esac
      for t in docker_network docker_volume docker_container; do
        k=$(jq -r --arg t $t '.[0].types | map(select(. == $t)) | length' <<<"$calls")
        if [ "$k" != 1 ]; then
          echo "not yet: $srcs declares $k $t blocks; it should declare exactly one."
          [ "$k" -gt 1 ] && echo "         Four blocks inside the module is the same copy-paste, one level down"
          exit 1
        fi
      done

      if [ "$rc" = 2 ]; then
        echo "not yet: tofu plan still wants changes:"
        jq -r '.resource_changes[]? | select(.change.actions != ["no-op"] or .previous_address != null) | "           " + (if .change.actions == ["no-op"] then "move" else (.change.actions | join("/")) end) + " \(.address)" + (if .previous_address then " (from \(.previous_address))" else "" end)' <<<"$pj" || true
        if jq -e '[.resource_changes[]? | select(.previous_address != null)] | length > 0' <<<"$pj" >/dev/null; then
          echo "         moved blocks only change the state when they are applied"
        fi
        if jq -e '[.resource_changes[]? | select(.change.actions | index("create"))] | length > 0' <<<"$pj" >/dev/null; then
          echo "         a create next to a delete is the same object at a new address. Tell"
          echo "         OpenTofu where each one moved instead of applying this"
        fi
        if jq -e '[.output_changes // {} | to_entries[] | select(.value.actions != ["no-op"])] | length > 0' <<<"$pj" >/dev/null; then
          echo "         an output changes too: see tofu output"
        fi
        exit 1
      fi

      n=$(jq '[.prior_state.values.root_module.child_modules[]?.resources[]? | select(.type=="docker_container")] | length' <<<"$pj")
      if [ "$n" != 4 ]; then
        echo "not yet: state holds $n containers inside modules; expected the four environments"
        exit 1
      fi

      if ! tofu output -json endpoints >$G/endpoints 2>/dev/null; then
        echo "not yet: there is no endpoints output any more, and deploy.sh reads it."
        echo "         A module's values reach the root only through the module's own outputs"
        exit 1
      fi
      if ! jq -e --slurpfile want /var/lib/devopslings/modules-and-outputs.endpoints '. == $want[0]' $G/endpoints >/dev/null; then
        echo "not yet: tofu output -json endpoints is $(jq -c . $G/endpoints)"
        echo "         deploy.sh expects $(jq -c . /var/lib/devopslings/modules-and-outputs.endpoints)"
        exit 1
      fi
      rm -rf $G

      echo "PASS — one module, four instances, the original networks, volumes and containers"
      echo "       with their settings intact, the same endpoints, and a clean plan."
---
