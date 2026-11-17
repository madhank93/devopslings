---
kind: lesson
title: "the build broke and nothing in the repo changed"
description: |
  Yesterday's build of `shop/web` was green. Today's, from the same commit, is
  red. Nobody touched the repository — the base image did. Make the build
  depend on the bytes it was tested with rather than on whatever an upstream
  tag points at today, so the next upstream push cannot change it.
name: base-image-by-digest
slug: base-image-by-digest
createdAt: "2026-11-14"

sandbox:
  stack: registry-stack
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 400
    run: |
      reset-registry
      reg=127.0.0.1:15000
      up=$reg/upstream/runtime
      stash=$reg/devopslings-grader/runtime
      crane auth login "$reg" -u devops -p devopslings >/dev/null 2>&1
      export DOCKER_CONFIG=$(mktemp -d)
      docker login "$reg" -u devops -p devopslings >/dev/null 2>&1
      docker pull -q busybox:1.37 >/dev/null

      for repo in "$up" "$stash"; do
        for tag in $(crane ls "$repo" 2>/dev/null || true); do
          crane delete "$repo@$(crane digest "$repo:$tag" 2>/dev/null)" 2>/dev/null || true
        done
      done

      # Three releases of the upstream runtime image. 2.5.0 changed how render
      # takes its arguments; 2.6.0 exists for the grader to publish later.
      b=$(mktemp -d)
      runtime() {
        ver=$1 flags=$2
        rm -rf "$b"/*
        printf 'runtime %s\n' "$ver" > "$b/runtime-release"
        if [ "$flags" = yes ]; then
          printf '%s\n' '#!/bin/sh' \
            '# render --in TEMPLATE --out FILE' \
            'set -eu' \
            '[ "${1:-}" = --in ] && [ "${3:-}" = --out ] || { echo "usage: render --in TEMPLATE --out FILE" >&2; exit 2; }' \
            'mkdir -p "$(dirname "$4")"' \
            'sed "s/{{runtime}}/$(cat /etc/runtime-release)/" "$2" > "$4"' > "$b/render"
        else
          printf '%s\n' '#!/bin/sh' \
            '# render TEMPLATE > FILE' \
            'set -eu' \
            'case "${1:-}" in -*|"") echo "render: unknown option ${1:-} (usage: render TEMPLATE > FILE)" >&2; exit 2 ;; esac' \
            'sed "s/{{runtime}}/$(cat /etc/runtime-release)/" "$1"' > "$b/render"
        fi
        chmod +x "$b/render"
        printf '%s\n' 'FROM busybox:1.37' \
          'COPY runtime-release /etc/runtime-release' \
          'COPY render /usr/local/bin/render' > "$b/Dockerfile"
        docker build -q -t "$stash:$ver" "$b" >/dev/null
        docker push -q "$stash:$ver" >/dev/null
        docker rmi "$stash:$ver" >/dev/null 2>&1 || true
      }
      runtime 2.4.1 yes
      runtime 2.5.0 no
      runtime 2.6.0 no
      rm -rf "$b"

      rm -rf /work/shop-web
      mkdir -p /work/shop-web/site /work/shop-web/ci/builds
      cd /work/shop-web
      cat > Dockerfile <<'DOCKER'
      FROM 127.0.0.1:15000/upstream/runtime:2
      COPY site/ /src/
      RUN render --in /src/index.tmpl --out /www/index.html
      CMD ["httpd", "-f", "-p", "8080", "-h", "/www"]
      DOCKER
      echo '<h1>shop</h1><p>served by {{runtime}}</p>' > site/index.tmpl

      # Yesterday: upstream's 2 still meant 2.4.1, and CI went green.
      crane copy "$stash:2.4.1" "$up:2.4.1" >/dev/null 2>&1
      crane tag "$up:2.4.1" 2 >/dev/null 2>&1
      crane tag "$up:2.4.1" latest >/dev/null 2>&1
      docker build --pull --no-cache --progress=plain -t devopslings-m11/shop-web:ci . \
        > ci/builds/1041.log 2>&1
      echo "result: success" >> ci/builds/1041.log

      # Overnight upstream released 2.5.0 and moved 2 and latest to it.
      crane copy "$stash:2.5.0" "$up:2.5.0" >/dev/null 2>&1
      crane tag "$up:2.5.0" 2 >/dev/null 2>&1
      crane tag "$up:2.5.0" latest >/dev/null 2>&1
      docker build --pull --no-cache --progress=plain -t devopslings-m11/shop-web:ci . \
        > ci/builds/1042.log 2>&1 || echo "result: failure" >> ci/builds/1042.log
      docker rmi devopslings-m11/shop-web:ci >/dev/null 2>&1 || true
      rm -rf "$DOCKER_CONFIG"

      echo "scenario ready — the repository is /work/shop-web"
      echo
      echo "  yesterday's build:  ci/builds/1041.log   (green)"
      echo "  today's build:      ci/builds/1042.log   (red, same commit)"
      echo "  upstream image:     127.0.0.1:15000/upstream/runtime"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 400
    run: |
      reg=127.0.0.1:15000
      up=$reg/upstream/runtime
      stash=$reg/devopslings-grader/runtime
      img=devopslings-m11/shop-web:verify
      work=$(mktemp -d)
      if ! crane auth login "$reg" -u devops -p devopslings >/dev/null 2>&1; then
        echo "not yet: the grader cannot log in to $reg. Reset the scenario."
        exit 1
      fi

      good=$(crane digest "$stash:2.4.1" 2>/dev/null || true)
      bad=$(crane digest "$stash:2.5.0" 2>/dev/null || true)
      if [ -z "$good" ] || [ -z "$bad" ]; then
        echo "not yet: the upstream image history is missing from the registry. Reset the scenario."
        exit 1
      fi

      # Upstream as the scenario left it: every release reachable by digest,
      # and the tags where upstream put them.
      upstream_as_published() {
        crane copy "$stash:2.4.1" "$up:2.4.1" >/dev/null 2>&1 &&
        crane copy "$stash:2.5.0" "$up:2.5.0" >/dev/null 2>&1 &&
        crane tag "$up:2.5.0" 2 >/dev/null 2>&1 &&
        crane tag "$up:2.5.0" latest >/dev/null 2>&1
      }
      trap 'upstream_as_published || true; docker rmi -f "$img" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT
      if ! upstream_as_published; then
        echo "not yet: the grader could not restore upstream/runtime in $reg. Reset the scenario."
        exit 1
      fi

      if [ ! -f /work/shop-web/Dockerfile ]; then
        echo "not yet: /work/shop-web/Dockerfile is missing."
        exit 1
      fi

      # Every base image the Dockerfile builds on, with ARG defaults expanded
      # and references to earlier stages left out.
      bases=$(python3 - /work/shop-web/Dockerfile <<'PY'
      import re, sys
      args, stages, out = {}, set(), []
      for line in open(sys.argv[1]):
          line = line.strip()
          m = re.match(r'(?i)ARG\s+(\w+)(?:=(\S+))?', line)
          if m:
              args[m.group(1)] = (m.group(2) or "").strip('"\'')
              continue
          m = re.match(r'(?i)FROM\s+(?:--\S+\s+)*(\S+)(?:\s+AS\s+(\S+))?', line)
          if m:
              ref = re.sub(r'\$\{?(\w+)\}?', lambda v: args.get(v.group(1), ""), m.group(1))
              if ref.lower() != "scratch" and ref not in stages:
                  out.append(ref)
              if m.group(2):
                  stages.add(m.group(2))
      print("\n".join(out))
      PY
      )
      if [ -z "$bases" ]; then
        echo "not yet: the Dockerfile has no FROM line the grader can read."
        exit 1
      fi

      # Builds the repository exactly as CI does: no cache, tags re-resolved.
      build() {
        docker rmi -f "$img" >/dev/null 2>&1 || true
        docker build --pull --no-cache --progress=plain -t "$img" /work/shop-web > "$work/build.log" 2>&1
      }
      release() { docker run --rm "$img" cat /etc/runtime-release 2>/dev/null || true; }

      if ! build; then
        echo "not yet: the build fails."
        for ref in $bases; do
          case $ref in
            *"$bad"*) echo "FROM $ref is runtime 2.5.0 — the release that broke the build." ;;
            *@sha256:*)
              d=${ref##*@}
              if ! crane manifest "${ref%%@*}@$d" >/dev/null 2>&1 && ! crane manifest "$up@$d" >/dev/null 2>&1; then
                echo "No registry has a manifest with digest $d. If you copied it from"
                echo "\`docker images\` or \`docker inspect\`, that is the image ID — the digest of the"
                echo "image's config — which the registry never sees. Pin the manifest digest."
              fi ;;
          esac
        done
        grep -E 'ERROR|error:|unknown option|usage:' "$work/build.log" | tail -3 || true
        exit 1
      fi
      rel=$(release)
      if [ "$rel" != "runtime 2.4.1" ]; then
        echo "not yet: the build is green, but on ${rel:-an image with no /etc/runtime-release}."
        echo "Adapting the Dockerfile to the new base works until upstream moves again;"
        echo "the build should run on what it was tested with, runtime 2.4.1."
        exit 1
      fi

      for ref in $bases; do
        case $ref in
          *@sha256:*) ;;
          *)
            echo "not yet: FROM $ref names a tag. Whoever can push to that tag decides what"
            echo "you build on — upstream rebuilds version tags too, and a copy under your own"
            echo "tag is one push away from changing. Pin the manifest digest."
            exit 1 ;;
        esac
      done

      # Upstream publishes 2.6.0 and re-pushes every tag it has, as an image
      # rebuild for a base-OS patch would.
      if ! ( for tag in 2.4.1 2.5.0 2.5 2 latest; do
               crane copy "$stash:2.6.0" "$up:$tag" >/dev/null 2>&1 || exit 1
             done
             crane copy "$stash@$good" "$up@$good" >/dev/null 2>&1 &&
             crane copy "$stash@$bad" "$up@$bad" >/dev/null 2>&1 ); then
        echo "not yet: the grader could not push runtime 2.6.0 to $up. Reset the scenario."
        exit 1
      fi

      if ! build; then
        echo "not yet: the grader pushed runtime 2.6.0 to every upstream tag, and your build"
        echo "broke. It still depends on a tag somewhere:"
        grep -E 'ERROR|error:' "$work/build.log" | tail -3 || true
        exit 1
      fi
      rel=$(release)
      if [ "$rel" != "runtime 2.4.1" ]; then
        echo "not yet: the grader pushed runtime 2.6.0 to every upstream tag, and your build"
        echo "now runs on ${rel:-something else}. Something in it still follows a tag."
        exit 1
      fi
      page=$(docker run --rm "$img" cat /www/index.html 2>/dev/null || true)
      case $page in
        *"runtime 2.4.1"*) ;;
        *)
          echo "not yet: the built image no longer serves the rendered page from site/index.tmpl."
          exit 1 ;;
      esac

      echo "PASS — the build runs on runtime 2.4.1 by digest, and an upstream push to"
      echo "every tag it has no longer changes what you build."
---

## Why this exists

`FROM python:3.12-slim` is a promise that the name means roughly the same thing
tomorrow. Upstream keeps that promise loosely: official images are rebuilt
under the same tags whenever their base OS gets a patch, and a minor version
tag moves with every release. Most of the time that is what you want. The day
it is not, your build breaks from a commit that built yesterday, and nothing
in your history explains why.

## Harbor and the real world

Harbor's *proxy cache* projects pull upstream images through your registry,
so an upstream deletion cannot take a base away from you — but they still
follow tags. Pinning by digest is a property of the Dockerfile, wherever the
image comes from. Renovate and Dependabot keep digest pins current by opening
a reviewed change when upstream moves.
