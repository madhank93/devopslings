---
kind: lesson
title: "production changed, and nobody deployed"
description: |
  Production runs the shop from `shop/web:latest`. Release 1.4.0 went out on
  Monday; on Wednesday a routine restart brought up a debug build nobody
  released, because CI pushes every build to `latest`. Put production back on
  the release, and make the next push to `latest` unable to touch it.
name: push-pull-and-mutable-tags
slug: push-pull-and-mutable-tags
createdAt: "2026-10-08"

sandbox:
  stack: registry-stack
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      reg=127.0.0.1:15000
      reset-registry
      repo=$reg/shop/web
      echo devopslings | docker login "$reg" -u devops --password-stdin >/dev/null 2>&1

      for tag in $(crane ls "$repo" 2>/dev/null || true); do
        crane delete "$repo@$(crane digest "$repo:$tag")" 2>/dev/null || true
      done
      docker rm -f shop-web >/dev/null 2>&1 || true
      docker pull -q busybox:1.37 >/dev/null

      rm -rf /work/shop /work/deploy
      mkdir -p /work/shop /work/deploy
      cat > /work/shop/Dockerfile <<'DOCKER'
      FROM busybox:1.37
      COPY index.html /www/index.html
      CMD ["httpd", "-f", "-p", "8080", "-h", "/www"]
      DOCKER

      cat > /work/deploy/compose.yaml <<'YAML'
      services:
        web:
          image: 127.0.0.1:15000/shop/web:latest
          container_name: shop-web
          pull_policy: always
          restart: unless-stopped
      YAML

      # The project name is the sandbox's own, so that tearing the sandbox down
      # also removes what was deployed on the host's daemon.
      cat > /work/deploy/deploy.sh <<'SH'
      #!/bin/sh
      # Production's deploy, and also what the nightly restart runs.
      set -eu
      cd "$(dirname "$0")"
      docker compose -p devopslings-registry-stack -f compose.yaml up -d --pull always web 2>&1 \
        | grep -v -i 'orphan' || true
      docker inspect shop-web --format 'shop-web is running {{.Config.Image}}'
      SH
      chmod +x /work/deploy/deploy.sh

      cat > /work/deploy/RELEASES.md <<'MD'
      # Releases

      | Version | Date       | Notes                         |
      |---------|------------|-------------------------------|
      | 1.4.0   | Monday     | Current production release.   |
      | 1.3.2   | last month | (superseded)                  |
      MD

      build() {
        echo "<h1>shop $1</h1>" > /work/shop/index.html
        docker build -q -t "$repo:$1" -t "$repo:latest" /work/shop >/dev/null
        docker push -q "$repo:$1" >/dev/null
        docker push -q "$repo:latest" >/dev/null
      }

      # Monday: the release, built and deployed.
      build 1.4.0
      /work/deploy/deploy.sh >/dev/null

      # Tuesday: CI builds a release candidate with debug logging and, as it does
      # for every build, pushes it to latest as well.
      build 1.5.0-rc1-debug

      # Wednesday: the nightly restart.
      /work/deploy/deploy.sh >/dev/null
      rm -f /root/.docker/config.json

      echo "scenario ready"
      echo
      echo "  deploy:    /work/deploy/   (compose.yaml, deploy.sh, RELEASES.md)"
      echo "  registry:  127.0.0.1:15000 (devops / devopslings)"
      echo
      echo "Production is serving:"
      echo "  $(curl -s http://shop-web:8080/)"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      reg=127.0.0.1:15000
      repo=$reg/shop/web

      export DOCKER_CONFIG=$(mktemp -d)
      prev_latest=""
      restore() {
        # Put latest back where the student left it, so the check is repeatable.
        if [ -n "$prev_latest" ]; then
          crane tag "$repo@$prev_latest" latest >/dev/null 2>&1 || true
        fi
        rm -rf "$DOCKER_CONFIG"
      }
      trap restore EXIT
      echo devopslings | docker login "$reg" -u devops --password-stdin >/dev/null 2>&1

      release=$(crane digest "$repo:1.4.0" 2>/dev/null || true)
      if [ -z "$release" ]; then
        echo "not yet: shop/web:1.4.0 is gone from the registry. Reset the scenario."
        exit 1
      fi
      release_cfg=$(crane manifest "$repo@$release" | jq -r .config.digest)

      # The daemon reports a container's image by config digest on the classic
      # store and by manifest digest on the containerd store; accept either.
      running_is_release() {
        _img=$(docker inspect shop-web --format '{{.Image}}' 2>/dev/null || true)
        [ "$_img" = "$release" ] || [ "$_img" = "$release_cfg" ]
      }

      ref=$(sed -n 's/^[[:space:]]*image:[[:space:]]*//p' /work/deploy/compose.yaml | head -1 | tr -d "\"'")
      case "$ref" in
        *@sha256:*) ;;
        *)
          echo "not yet: /work/deploy/compose.yaml deploys '$ref'. That is a tag, and"
          echo "a tag is a pointer anyone with push access can move — a version tag"
          echo "included. Pin the digest."
          exit 1
          ;;
      esac
      if [ "${ref##*@}" = "$release_cfg" ]; then
        echo "not yet: compose.yaml pins ${ref##*@}, which is 1.4.0's image ID —"
        echo "the digest of its config, as \`docker images\` and \`docker inspect .Id\` show it."
        echo "The registry has no manifest by that digest; pin the manifest digest,"
        echo "$release."
        exit 1
      fi
      if [ "${ref##*@}" != "$release" ]; then
        echo "not yet: compose.yaml pins ${ref##*@},"
        echo "but release 1.4.0 is $release."
        exit 1
      fi

      if ! running_is_release; then
        served=$(curl -s --max-time 5 http://shop-web:8080/ 2>/dev/null || true)
        echo "not yet: production is not running release 1.4.0. It is serving:"
        echo "  ${served:-nothing at all}"
        echo "compose.yaml pins the right digest; run /work/deploy/deploy.sh to deploy it."
        exit 1
      fi

      # Now be CI: push a new build to latest, run the routine deploy, and see
      # whether production moved.
      prev_latest=$(crane digest "$repo:latest" 2>/dev/null || true)
      work=$(mktemp -d)
      printf 'FROM busybox:1.37\nRUN mkdir /www && echo "<h1>grader build %s</h1>" > /www/index.html\nCMD ["httpd","-f","-p","8080","-h","/www"]\n' "$$" > "$work/Dockerfile"
      docker build -q -t "$repo:latest" "$work" >/dev/null
      docker push -q "$repo:latest" >/dev/null
      rm -rf "$work"

      if ! /work/deploy/deploy.sh >/dev/null 2>&1; then
        echo "not yet: /work/deploy/deploy.sh failed after the grader pushed to latest."
        echo "Production has to survive a redeploy, not only stay up until the next one."
        exit 1
      fi
      if ! running_is_release; then
        echo "not yet: the grader pushed a new image to latest and ran deploy.sh, and"
        echo "production changed. Whatever compose.yaml says, something still follows"
        echo "the tag."
        exit 1
      fi

      echo "PASS — production runs $release,"
      echo "and a push to latest no longer reaches it."
---
