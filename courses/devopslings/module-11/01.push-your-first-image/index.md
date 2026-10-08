---
kind: lesson
title: "push an image, then find it again"
description: |
  Build an image, push it to a registry under a version and under latest, push
  a second build the same way, and fetch both back from a client that never
  built either.
  Learn what a tag names, what a digest names, and why the image ID that
  `docker images` prints is neither.
name: push-your-first-image
slug: push-your-first-image
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
      crane auth login "$reg" -u devops -p devopslings >/dev/null 2>&1

      # Start from an empty repository. A tag left by an earlier attempt would
      # make the first push look like the second.
      for tag in $(crane ls "$reg/hello/web" 2>/dev/null || true); do
        crane delete "$reg/hello/web@$(crane digest "$reg/hello/web:$tag")" 2>/dev/null || true
      done
      docker logout "$reg" >/dev/null 2>&1 || true
      rm -f /root/.docker/config.json

      rm -rf /work/hello /work/answer.txt
      mkdir -p /work/hello
      cat > /work/hello/Dockerfile <<'DOCKER'
      FROM busybox:1.37
      COPY index.html /www/index.html
      CMD ["httpd", "-f", "-p", "8080", "-h", "/www"]
      DOCKER
      echo '<h1>hello, version one</h1>' > /work/hello/index.html

      cat > /work/answer.txt <<'TXT'
      # The digest 127.0.0.1:15000/hello/web:latest resolved to after your FIRST push.
      first=

      # The digest the same tag resolves to after your SECOND push.
      second=
      TXT

      # Pull the base now, so the first build is about the registry and not
      # about Docker Hub.
      docker pull -q busybox:1.37 >/dev/null

      echo "scenario ready — the image to build is in /work/hello"
      echo
      echo "  registry:  127.0.0.1:15000   (devops / devopslings)"
      echo "  answers:   /work/answer.txt"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 120
    run: |
      reg=127.0.0.1:15000
      repo="$reg/hello/web"
      accept='application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json'

      # The grader reads the registry with its own credentials and no local
      # image store — a second client, which is the point.
      export DOCKER_CONFIG=$(mktemp -d)
      trap 'rm -rf "$DOCKER_CONFIG"' EXIT
      crane auth login "$reg" -u devops -p devopslings >/dev/null 2>&1

      answer() { sed -n "s/^$1=[[:space:]]*//p" /work/answer.txt 2>/dev/null | tr -d '[:space:]' | head -1; }
      # Status code for a manifest lookup by digest; 404 means the registry has
      # no manifest with that digest in this repository.
      manifest_status() {
        curl -s -o /dev/null -w '%{http_code}' -u devops:devopslings \
          -H "Accept: $accept" "http://$reg/v2/hello/web/manifests/$1"
      }

      latest=$(crane digest "$repo:latest" 2>/dev/null || true)
      v10=$(crane digest "$repo:1.0" 2>/dev/null || true)
      v11=$(crane digest "$repo:1.1" 2>/dev/null || true)
      if [ -z "$v10" ] || [ -z "$latest" ]; then
        echo "not yet: the registry needs hello/web:1.0 and hello/web:latest. Build"
        echo "/work/hello, tag the image with both names, log in and push both."
        exit 1
      fi
      if [ -z "$v11" ]; then
        echo "not yet: there is no hello/web:1.1. Change /work/hello/index.html, build"
        echo "again, and push the new image as 1.1 and as latest."
        exit 1
      fi

      first=$(answer first)
      second=$(answer second)
      for pair in "first:$first" "second:$second"; do
        name=${pair%%:*}
        value=${pair#*:}
        if ! printf '%s' "$value" | grep -Eq '^sha256:[0-9a-f]{64}$'; then
          echo "not yet: '$name=' in /work/answer.txt is '${value:-empty}'. A digest is"
          echo "written sha256: followed by 64 hex characters."
          exit 1
        fi
        if [ "$(manifest_status "$value")" != 200 ]; then
          echo "not yet: the registry has no manifest $value in hello/web, so '$name='"
          echo "is not something it can serve. If you copied it from 'docker images' or"
          echo "'docker inspect .Id', that is the image ID — the digest of the image's"
          echo "config, which the daemon uses locally. The registry addresses the image by"
          echo "the digest of its manifest; 'docker push' prints it on its last line."
          exit 1
        fi
      done

      if [ "$first" = "$second" ]; then
        echo "not yet: first= and second= are the same digest. Change"
        echo "/work/hello/index.html between the two builds — a new build is a new"
        echo "manifest, and a new manifest is a new digest."
        exit 1
      fi
      if [ "$first" != "$v10" ]; then
        echo "not yet: first= is not the image hello/web:1.0 names ($v10)."
        echo "After the first push, latest and 1.0 were two names for one manifest."
        exit 1
      fi
      if [ "$second" != "$latest" ] || [ "$second" != "$v11" ]; then
        echo "not yet: second= should be what latest names now. latest is"
        echo "$latest and 1.1 is $v11; after the second push"
        echo "both names should point at the second build."
        exit 1
      fi

      # Both builds must be fetchable by digest, by a client that never had them.
      for d in "$first" "$second"; do
        if ! crane export "$repo@$d" - 2>/dev/null | tar -xO www/index.html >/dev/null 2>&1; then
          echo "not yet: $repo@$d does not unpack to an image containing"
          echo "/www/index.html. Push builds of /work/hello, not some other image."
          exit 1
        fi
      done
      one=$(crane export "$repo@$first" - | tar -xO www/index.html)
      two=$(crane export "$repo@$second" - | tar -xO www/index.html)
      if [ "$one" = "$two" ]; then
        echo "not yet: both digests serve the same index.html. Edit it between the two"
        echo "builds, so you can see which build each name fetches."
        exit 1
      fi

      echo "PASS — latest moved from the first build to the second; the digests did not:"
      echo "  $repo@$first   (1.0)"
      echo "  $repo@$second   (1.1, latest)"
---
