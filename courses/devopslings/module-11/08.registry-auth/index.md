---
kind: lesson
title: "CI can pull, production cannot"
description: |
  Last week the registry stopped allowing anonymous pulls, and CI carried on
  as if nothing had happened. Production did not: this morning's deploy failed
  with `UNAUTHORIZED`. Give the runtime an account of its own that can pull
  what it deploys and nothing else — without opening the registry back up and
  without handing it CI's push credentials.
name: registry-auth
slug: registry-auth
createdAt: "2026-11-14"

sandbox:
  stack: registry-stack
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      reset-registry
      reg=127.0.0.1:15000
      cfg=/etc/registry/config.json

      # Last week's lockdown: shop/ is CI's to push, finance/ belongs to another
      # team, and nothing is readable without an account.
      jq '.http.accessControl.repositories = {
            "shop/**": {
              "policies": [{ "users": ["ci"], "actions": ["read", "create", "update"] }],
              "defaultPolicy": []
            },
            "finance/**": {
              "policies": [{ "users": ["finance-ci"], "actions": ["read", "create", "update"] }],
              "defaultPolicy": []
            },
            "upstream/**": { "anonymousPolicy": ["read"], "defaultPolicy": [] },
            "**": { "defaultPolicy": [] }
          }' "$cfg" > /tmp/config.json
      cat /tmp/config.json > "$cfg"
      rm -f /tmp/config.json
      htpasswd -Bb /etc/registry/htpasswd ci ci-builds-and-pushes 2>/dev/null
      htpasswd -Bb /etc/registry/htpasswd finance-ci ledger-team-only 2>/dev/null
      sleep 2

      export DOCKER_CONFIG=$(mktemp -d)
      crane auth login "$reg" -u devops -p devopslings >/dev/null 2>&1
      work=$(mktemp -d)
      image() {
        for tag in $(crane ls "$reg/$1" 2>/dev/null || true); do
          crane delete "$reg/$1@$(crane digest "$reg/$1:$tag" 2>/dev/null)" 2>/dev/null || true
        done
        printf '{"service":"%s","version":"%s"}\n' "$1" "$2" > "$work/build.json"
        tar -C "$work" -cf "$work/layer.tar" build.json
        crane append -f "$work/layer.tar" -t "$reg/$1:$2" >/dev/null 2>&1
      }
      image shop/web 1.4.0
      image shop/cart 2.0.1
      image finance/ledger 3.2.0
      rm -rf "$work" "$DOCKER_CONFIG"
      unset DOCKER_CONFIG

      rm -rf /work/runtime /work/ci
      mkdir -p /work/runtime/docker /work/ci/docker
      echo '{"auths":{}}' > /work/runtime/docker/config.json
      printf '{"auths":{"%s":{"auth":"%s"}}}\n' "$reg" \
        "$(printf 'ci:ci-builds-and-pushes' | base64)" > /work/ci/docker/config.json

      cat > /work/runtime/deploy.sh <<'SH'
      #!/bin/sh
      # How a production node fetches what it is told to run: with the
      # credentials in /work/runtime/docker, and nothing else.
      # Usage: deploy.sh <image-reference>
      set -eu
      ref=${1:?usage: deploy.sh <image-reference>}
      DOCKER_CONFIG=/work/runtime/docker crane manifest "$ref" >/dev/null
      echo "pulled $ref"
      SH
      chmod +x /work/runtime/deploy.sh

      echo "scenario ready"
      echo
      echo "  production deploys:  /work/runtime/deploy.sh 127.0.0.1:15000/shop/web:1.4.0"
      echo "                       /work/runtime/deploy.sh 127.0.0.1:15000/shop/cart:2.0.1"
      echo "  its credentials:     /work/runtime/docker/config.json"
      echo "  CI's credentials:    /work/ci/docker/config.json"
      echo "  registry config:     /etc/registry/config.json and /etc/registry/htpasswd"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      reg=127.0.0.1:15000
      work=$(mktemp -d)
      admin=$work/admin
      mkdir -p "$admin"
      cleanup() {
        for r in shop/web unclaimed/grader-probe; do
          DOCKER_CONFIG=$admin crane delete "$reg/$r@$(DOCKER_CONFIG=$admin crane digest "$reg/$r:grader-probe" 2>/dev/null)" >/dev/null 2>&1 || true
        done
        rm -rf "$work"
      }
      trap cleanup EXIT

      code() { curl -s -o /dev/null -w '%{http_code}' "$@" || true; }
      manifest=application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json

      if [ "$(code -u devops:devopslings "http://$reg/v2/_catalog")" != 200 ]; then
        echo "not yet: the devops account can no longer log in. If you ran \`htpasswd -c\`,"
        echo "it recreated /etc/registry/htpasswd with only your new user in it. Reset the"
        echo "scenario, and add users without -c."
        exit 1
      fi
      DOCKER_CONFIG=$admin crane auth login "$reg" -u devops -p devopslings >/dev/null 2>&1

      if [ "$(code -H "Accept: $manifest" "http://$reg/v2/shop/web/manifests/1.4.0")" = 200 ]; then
        echo "not yet: shop/web can be pulled with no credentials at all. That is the"
        echo "registry opened back up: anyone who can reach it can read every release."
        exit 1
      fi

      creds=$(jq -r --arg r "$reg" '.auths[$r].auth // empty' /work/runtime/docker/config.json 2>/dev/null || true)
      if [ -z "$creds" ]; then
        echo "not yet: /work/runtime/docker/config.json has no credentials for $reg."
        exit 1
      fi
      userpass=$(printf '%s' "$creds" | base64 -d 2>/dev/null || true)
      user=${userpass%%:*}
      case $user in
        devops)
          echo "not yet: production is using the registry's admin account. A compromised"
          echo "node could now delete every release. Give it an account of its own."
          exit 1 ;;
        ci)
          echo "not yet: production is using CI's account, which can push. A compromised"
          echo "node could now replace the images every other node pulls."
          exit 1 ;;
        finance-ci)
          echo "not yet: production is using the finance team's account."
          exit 1 ;;
      esac

      as_runtime() { DOCKER_CONFIG=/work/runtime/docker "$@"; }
      for ref in shop/web:1.4.0 shop/cart:2.0.1; do
        if ! out=$(as_runtime /work/runtime/deploy.sh "$reg/$ref" 2>&1); then
          echo "not yet: production still cannot pull $ref as '$user':"
          echo "  $out" | tail -1
          exit 1
        fi
      done

      # Every probe image has content of its own, so deleting it afterwards can
      # never take a real release's manifest with it.
      printf 'probe %s\n' "$$" > "$work/probe"
      tar -C "$work" -cf "$work/probe.tar" probe
      if as_runtime crane append -f "$work/probe.tar" -t "$reg/shop/web:grader-probe" >/dev/null 2>&1; then
        echo "not yet: '$user' can push to shop/web — the grader just did, with production's"
        echo "credentials. Production only ever needs to read."
        exit 1
      fi
      # Re-puts 1.4.0's own manifest: an overwrite that changes nothing if allowed.
      m=$(DOCKER_CONFIG=$admin crane manifest "$reg/shop/web:1.4.0")
      mt=$(printf '%s' "$m" | jq -r .mediaType)
      if [ "$(code -u "$userpass" -X PUT -H "Content-Type: $mt" --data-binary "$m" \
              "http://$reg/v2/shop/web/manifests/1.4.0")" = 201 ]; then
        echo "not yet: '$user' can overwrite existing tags in shop/web."
        exit 1
      fi

      DOCKER_CONFIG=$admin crane append -f "$work/probe.tar" -t "$reg/shop/web:grader-probe" >/dev/null 2>&1
      d=$(DOCKER_CONFIG=$admin crane digest "$reg/shop/web:grader-probe")
      if [ "$(code -u "$userpass" -X DELETE "http://$reg/v2/shop/web/manifests/$d")" = 202 ]; then
        echo "not yet: '$user' can delete from shop/web. It just deleted the grader's probe."
        exit 1
      fi

      if [ "$(code -u "$userpass" -H "Accept: $manifest" "http://$reg/v2/finance/ledger/manifests/3.2.0")" = 200 ]; then
        echo "not yet: '$user' can read finance/ledger. Production runs the shop; another"
        echo "team's images are not its business, and a stolen node token should not be"
        echo "either."
        exit 1
      fi

      # A repository no rule names, as the next team to start pushing would create.
      DOCKER_CONFIG=$admin crane append -f "$work/probe.tar" -t "$reg/unclaimed/grader-probe:grader-probe" >/dev/null 2>&1
      if [ "$(code -u "$userpass" -H "Accept: $manifest" "http://$reg/v2/unclaimed/grader-probe/manifests/grader-probe")" = 200 ]; then
        echo "not yet: '$user' can read unclaimed/grader-probe, a repository the grader just"
        echo "created that no rule names. Its read access is not scoped to shop/ — it covers"
        echo "every repository nobody has written a rule for yet."
        exit 1
      fi
      if [ "$(code -u finance-ci:ledger-team-only -H "Accept: $manifest" "http://$reg/v2/shop/web/manifests/1.4.0")" = 200 ]; then
        echo "not yet: finance-ci can read shop/web. The read was granted to every account"
        echo "that can log in, not to production's — a default policy, not a scoped one."
        exit 1
      fi

      ci=$(printf 'ci:ci-builds-and-pushes')
      if [ "$(code -u "$ci" -H "Accept: $manifest" "http://$reg/v2/shop/web/manifests/1.4.0")" != 200 ] \
         || ! DOCKER_CONFIG=/work/ci/docker crane append -f "$work/probe.tar" -t "$reg/shop/web:grader-probe" >/dev/null 2>&1; then
        echo "not yet: CI can no longer pull and push shop/web with its own account."
        exit 1
      fi

      echo "PASS — production pulls shop/web and shop/cart as '$user', which cannot push,"
      echo "overwrite, delete, or read finance/; anonymous pulls stay refused; CI still pushes."
---

## Why this exists

Registry credentials are some of the most widely copied secrets in a company:
every node, every CI runner, every developer laptop has one. Whatever the
weakest of those can do, an attacker who reaches it can do. A pull credential
on a production node that can also push turns one compromised node into a
compromised fleet — the next deploy pulls whatever the attacker pushed.

## Harbor and the real world

Harbor calls these *robot accounts*: credentials that are not people, scoped
to projects and to actions (pull, push, delete), with an expiry date. ECR does
the same with IAM policies (`ecr:BatchGetImage` without `ecr:PutImage`), GCR
and Artifact Registry with `roles/artifactregistry.reader`. zot has no
separate robot type; an htpasswd user with a read-only policy is the same
thing.
