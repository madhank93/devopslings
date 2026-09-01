---
kind: lesson
title: "exec format error on the runner, and the same image is fine on your laptop"
description: |
  The image builds, runs locally, and dies instantly on the CI runner. Learn
  what an image's architecture actually claims, why a multi-platform build can
  still ship the wrong binary, and how to check before you push.
name: exec-format-error
slug: exec-format-error
createdAt: "2026-09-01"

sandbox:
  stack: none
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 600
    run: |
      reg=devopslings-registry
      builder=devopslings-xarch

      cat > main.go <<'GO'
      package main

      import "fmt"

      func main() { fmt.Println("pricing-agent v1 ok") }
      GO

      # The cross-compiling pattern, half applied: the builder stage is pinned to
      # the machine doing the building, and nothing tells the compiler what it is
      # building for.
      cat > Dockerfile <<'DOCKER'
      FROM --platform=$BUILDPLATFORM golang:1.23-alpine AS build
      WORKDIR /src
      COPY main.go .
      RUN go build -o /out/app main.go

      FROM alpine:3.20
      COPY --from=build /out/app /usr/local/bin/app
      CMD ["app"]
      DOCKER

      cat > build.sh <<'SH'
      #!/usr/bin/env bash
      # What CI runs to publish the agent. The grader runs this too.
      set -euo pipefail
      docker buildx build --builder devopslings-xarch \
        --push -t localhost:5001/pricing-agent:1 .
      SH
      chmod +x build.sh

      # A registry to publish to and a builder that can reach it. Both are part
      # of the bench, not the exercise.
      docker rm -f "$reg" >/dev/null 2>&1 || true
      docker run -d --name "$reg" -p 5001:5000 registry:2 >/dev/null
      if ! docker buildx inspect "$builder" >/dev/null 2>&1; then
        docker buildx create --name "$builder" --driver docker-container \
          --driver-opt network=host >/dev/null
      fi

      echo "scenario ready — files are in $(pwd)"
      echo
      echo "See it:"
      echo "  ./build.sh"
      echo "  docker buildx imagetools inspect localhost:5001/pricing-agent:1"
      echo "  # the runner is linux/amd64"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 900
    run: |
      reg=devopslings-registry
      builder=devopslings-xarch
      ref=localhost:5001/pricing-agent:1
      expected='pricing-agent v1 ok'

      for f in main.go Dockerfile build.sh; do
        if [ ! -f "$f" ]; then
          echo "not yet: no $f in $(pwd)"
          exit 1
        fi
      done

      # A fresh registry, so what is graded is what this build just published and
      # not what an earlier attempt left behind.
      docker rm -f "$reg" >/dev/null 2>&1 || true
      docker run -d --name "$reg" -p 5001:5000 registry:2 >/dev/null
      if ! docker buildx inspect "$builder" >/dev/null 2>&1; then
        docker buildx create --name "$builder" --driver docker-container \
          --driver-opt network=host >/dev/null
      fi
      sleep 2

      if ! out=$(bash build.sh 2>&1); then
        echo "not yet: build.sh failed:"
        printf '%s\n' "$out" | tail -15 | sed 's/^/    /'
        exit 1
      fi

      if ! manifest=$(docker buildx imagetools inspect "$ref" 2>&1); then
        echo "not yet: nothing published at $ref:"
        printf '%s\n' "$manifest" | tail -6 | sed 's/^/    /'
        echo "build.sh has to push to the registry — that is what the runner pulls from."
        exit 1
      fi

      for want in linux/amd64 linux/arm64; do
        case "$manifest" in
          *"$want"*) ;;
          *)
            echo "not yet: $ref has no $want in its manifest. It holds:"
            printf '%s\n' "$manifest" | grep -i 'platform' | sed 's/^/    /' || true
            echo "One image can carry a manifest for each architecture. Ask the build for"
            echo "both, and push the result rather than loading it locally."
            exit 1
            ;;
        esac
      done

      # The manifest is a claim. Check the bytes: an ELF header names the machine
      # it was compiled for in two bytes at offset 18, and that is what the kernel
      # on the runner will look at before it refuses to run it.
      elf_arch() {
        case "$1" in
          3e00) echo amd64 ;;
          b700) echo arm64 ;;
          *)    echo "unknown($1)" ;;
        esac
      }

      for plat in amd64 arm64; do
        if ! docker pull -q --platform "linux/$plat" "$ref" >/dev/null 2>&1; then
          echo "not yet: could not pull the linux/$plat image from the registry"
          exit 1
        fi
        claimed=$(docker image inspect -f '{{.Architecture}}' "$ref")
        c=$(docker create --platform "linux/$plat" "$ref" 2>/dev/null)
        docker cp "$c:/usr/local/bin/app" .verify-app.bin >/dev/null 2>&1 || true
        docker rm "$c" >/dev/null 2>&1 || true
        if [ ! -f .verify-app.bin ]; then
          echo "not yet: the linux/$plat image has no /usr/local/bin/app in it"
          exit 1
        fi
        bytes=$(od -An -tx1 -j18 -N2 .verify-app.bin | tr -d ' \n')
        rm -f .verify-app.bin
        actual=$(elf_arch "$bytes")

        if [ "$actual" != "$plat" ]; then
          echo "not yet: the linux/$plat image ships a binary compiled for $actual."
          echo "The manifest says $claimed and /usr/local/bin/app was compiled for"
          echo "$actual, so the kernel that loads it reports 'exec format error'."
          echo "The build stage runs on the build machine — say what it is building for."
          exit 1
        fi
      done

      host=$(docker version -f '{{.Server.Arch}}' 2>/dev/null || echo amd64)
      got=$(docker run --rm --platform "linux/$host" "$ref" 2>&1 || true)
      if [ "$got" != "$expected" ]; then
        echo "not yet: the linux/$host image does not run. It said:"
        printf '%s\n' "$got" | tail -6 | sed 's/^/    /'
        exit 1
      fi

      echo "PASS — $ref carries linux/amd64 and linux/arm64, each holding a binary"
      echo "compiled for the architecture its manifest claims."
---
