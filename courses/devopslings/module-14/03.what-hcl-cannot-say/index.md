---
kind: lesson
title: "three sites, three shapes, one input"
description: |
  The edge program builds one web container per site, whatever the site's
  config asks for. A site with replicas needs a load balancer in front of
  them, and some sites need a cache. Make one program build every shape from
  the config alone, and make changing the config touch only what changed.
name: what-hcl-cannot-say
slug: what-hcl-cannot-say
createdAt: "2026-11-13"

sandbox:
  stack: iac-stack
  service: ws

tasks:
  init_scenario:
    init: true
    timeout_seconds: 240
    run: |
      docker rm -f $(docker ps -aq) >/dev/null 2>&1 || true
      for n in $(docker network ls -q --filter name=edge- 2>/dev/null); do docker network rm "$n" >/dev/null 2>&1 || true; done
      rm -rf /root/edge /var/lib/pulumi/edge
      install -d /root/edge /var/lib/pulumi/edge
      cd /root/edge

      cp /opt/pulumi-template/go.mod /opt/pulumi-template/go.sum .
      sed -i 's/^module program$/module edge/' go.mod
      cat > Pulumi.yaml <<'YAML'
      name: edge
      runtime: go
      description: one network per site, and whatever containers the site needs
      backend:
        url: file:///var/lib/pulumi/edge
      YAML
      cat > Pulumi.dev.yaml <<'YAML'
      config:
        edge:sites:
          - name: eu
            replicas: 3
            cache: true
          - name: us
            replicas: 1
            cache: false
      YAML

      cat > main.go <<'GO'
      package main

      import (
      	"github.com/pulumi/pulumi-docker/sdk/v5/go/docker"
      	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
      	"github.com/pulumi/pulumi/sdk/v3/go/pulumi/config"
      )

      // Site is one entry of the edge:sites config list.
      type Site struct {
      	Name     string `json:"name"`
      	Replicas int    `json:"replicas"`
      	Cache    bool   `json:"cache"`
      }

      func main() {
      	pulumi.Run(func(ctx *pulumi.Context) error {
      		var sites []Site
      		config.New(ctx, "").RequireObject("sites", &sites)

      		for _, s := range sites {
      			net, err := docker.NewNetwork(ctx, "edge-"+s.Name, &docker.NetworkArgs{
      				Name: pulumi.String("edge-" + s.Name),
      			})
      			if err != nil {
      				return err
      			}
      			if _, err := container(ctx, s.Name+"-web-0", net, "SITE="+s.Name); err != nil {
      				return err
      			}
      		}
      		return nil
      	})
      }

      // container runs one busybox httpd called name on net, with env as its
      // environment.
      func container(ctx *pulumi.Context, name string, net *docker.Network, env ...string) (*docker.Container, error) {
      	return docker.NewContainer(ctx, name, &docker.ContainerArgs{
      		Name:    pulumi.String(name),
      		Image:   pulumi.String("busybox:1.37.0"),
      		Envs:    pulumi.ToStringArray(env),
      		Command: pulumi.ToStringArray([]string{"httpd", "-f", "-p", "8080", "-h", "/www"}),
      		NetworksAdvanced: docker.ContainerNetworksAdvancedArray{
      			docker.ContainerNetworksAdvancedArgs{Name: net.Name},
      		},
      	})
      }
      GO

      cat > README <<'TXT'
      Every site in edge:sites (Pulumi.dev.yaml) should get, on its own
      network edge-<site>:

        <site>-web-0 .. <site>-web-<replicas-1>   env SITE=<site>
        <site>-lb     only when replicas > 1      env UPSTREAMS=<site>-web-0 <site>-web-1 ...
                                                  (every web, in order, space-separated)
        <site>-cache  only when cache is true     no env

      and nothing else. Today the program builds <site>-web-0 and stops.

      The check deploys the dev stack with other site lists as well, so the
      program has to follow the config, not the two sites in it now. When the
      list changes, a container whose site is unchanged must not be replaced,
      wherever its site sits in the list.
      TXT

      pulumi stack init dev --non-interactive >/dev/null 2>&1
      pulumi up -s dev --yes --non-interactive >/dev/null
      echo "scenario ready — /root/edge builds one web per site, whatever the config says"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 420
    run: |
      if ! cd /root/edge 2>/dev/null || [ ! -f Pulumi.dev.yaml ]; then
        echo "not yet: /root/edge or its Pulumi.dev.yaml is gone — reset the lesson"
        exit 1
      fi
      if ! out=$(go build -o /dev/null . 2>&1); then
        echo "not yet: the program does not build:"
        grep -m3 -E '\.go:[0-9]+' <<<"$out" | sed 's/^/         /' || true
        exit 1
      fi

      # The check deploys its own site lists, then puts the student's back.
      install -d /var/lib/devopslings
      saved=/var/lib/devopslings/what-hcl-cannot-say.yaml
      cp Pulumi.dev.yaml "$saved"
      trap 'cp "$saved" /root/edge/Pulumi.dev.yaml' EXIT

      # expect "site:replicas:cache ...": prints one "name|network|env" line per container.
      expect() {
        local s n r c i up
        for s in "$@"; do
          IFS=: read -r n r c <<<"$s"
          up=""
          for ((i = 0; i < r; i++)); do
            echo "$n-web-$i|edge-$n|SITE=$n"
            up="$up $n-web-$i"
          done
          [ "$r" -gt 1 ] && echo "$n-lb|edge-$n|UPSTREAMS=${up# }"
          [ "$c" = true ] && echo "$n-cache|edge-$n|"
        done | sort
      }
      actual() {
        local id
        for id in $(docker ps -aq); do
          docker inspect "$id" | jq -r '.[0] | "\(.Name|ltrimstr("/"))|\(.NetworkSettings.Networks|keys|join(","))|\((.Config.Env // []) | map(select(startswith("SITE=") or startswith("UPSTREAMS="))) | join(","))"'
        done | sort
      }
      config_for() {
        local s n r c
        echo "config:"
        echo "  edge:sites:"
        for s in "$@"; do
          IFS=: read -r n r c <<<"$s"
          printf '    - name: %s\n      replicas: %s\n      cache: %s\n' "$n" "$r" "$c"
        done
      }
      deploy() {
        local label=$1 out want got
        shift
        config_for "$@" > Pulumi.dev.yaml
        if ! out=$(pulumi up -s dev --yes --non-interactive 2>&1); then
          echo "not yet: pulumi up fails with $label:"
          grep -m3 'error:' <<<"$out" | sed 's/^/         /' || true
          if grep -Eq 'already (exists|in use)' <<<"$out"; then
            echo "         Pulumi created a resource under a new logical name (the first argument"
            echo "         to New...) while the old one still held its Docker name. A logical name"
            echo "         taken from a position in the list moves when the list does; derive it"
            echo "         from the site's name instead. pulumi preview --diff shows the moves"
          elif grep -q 'replacement' <<<"$out"; then
            echo "         Pulumi tried to replace a resource whose site did not change. Resources"
            echo "         are matched by logical name, the first argument to New...; a name taken"
            echo "         from a position in the list moves when the list does"
          fi
          exit 1
        fi
        want=$(expect "$@") got=$(actual)
        if [ "$want" != "$got" ]; then
          echo "not yet: with $label, the containers are not what the README asks for"
          echo "         (name | network | SITE/UPSTREAMS env):"
          diff <(echo "$want") <(echo "$got") | sed -n 's/^< /           missing:    /p; s/^> /           unexpected: /p' || true
          exit 1
        fi
      }
      id_of() { docker inspect -f '{{.Id}}' "$1" 2>/dev/null || true; }
      net_of() { docker network inspect -f '{{.Id}}' "$1" 2>/dev/null || true; }

      a="sites eu (3 replicas, cache) and us (1 replica, no cache)"
      deploy "$a" eu:3:true us:1:false
      eu_web=$(id_of eu-web-0) eu_net=$(net_of edge-eu)

      b="sites ap (2 replicas, cache) and eu (1 replica, no cache), in that order"
      deploy "$b" ap:2:true eu:1:false
      if [ "$(id_of eu-web-0)" != "$eu_web" ] || [ "$(net_of edge-eu)" != "$eu_net" ]; then
        echo "not yet: eu-web-0 or edge-eu was replaced when the site list changed, though eu's"
        echo "         web-0 and network did not change. Pulumi matches resources by their"
        echo "         logical name, the first argument to New...; if that name comes from a"
        echo "         position in the list, moving a site renames everything after it"
        exit 1
      fi

      deploy "a site list with one site, solo (1 replica, cache)" solo:1:true

      # Back to the student's own config and deployment.
      cp "$saved" Pulumi.dev.yaml
      if ! out=$(pulumi up -s dev --yes --non-interactive 2>&1); then
        echo "not yet: pulumi up fails with your own Pulumi.dev.yaml:"
        grep -m3 'error:' <<<"$out" | sed 's/^/         /' || true
        exit 1
      fi
      echo "PASS — one program builds every shape the config asks for, and a change to the"
      echo "       list touches only the sites that changed."
---
