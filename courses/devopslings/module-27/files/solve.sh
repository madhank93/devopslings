#!/usr/bin/env bash
# Stage 1's reference solution, for stage 1's contract and for later stages
# whose init finds stage 1 unsolved.
# The build tags by commit; a deploy job resolves that tag's digest and plans
# and applies it from the shared state; the config runs two replicas.
set -euo pipefail

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

git clone -q "http://devops:devopslings@127.0.0.1:3000/devops/checkout.git" "$work/checkout"
cd "$work/checkout"
git config user.email devops@example.invalid
git config user.name devops

cat > .forgejo/workflows/ci.yml <<'YAML'
name: ci

on: [push]

env:
  IMAGE: 127.0.0.1:5000/checkout

jobs:
  build:
    runs-on: docker
    container:
      image: docker:27-cli
      options: -v /var/run/docker.sock:/var/run/docker.sock
    steps:
      - run: |
          git clone -q http://forge:3000/devops/checkout.git .
          git checkout -q "${{ github.sha }}"
          docker build -t "${IMAGE}:${{ github.sha }}" .
          docker push "${IMAGE}:${{ github.sha }}"

  deploy:
    runs-on: docker
    needs: [build]
    container:
      image: devopslings-ha-stack-ops
      options: -v /var/run/docker.sock:/var/run/docker.sock
    steps:
      - run: |
          git clone -q http://forge:3000/devops/checkout.git .
          git checkout -q "${{ github.sha }}"
          digest=$(curl -fsSI \
            -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
            "http://registry:5000/v2/checkout/manifests/${{ github.sha }}" \
            | tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" { print $2 }')
          test -n "$digest"
          cd deploy
          tofu init -input=false
          tofu plan -input=false -out=tfplan -var "image=${IMAGE}@${digest}"
          tofu apply -input=false tfplan
YAML

# Two replicas, one per address HAProxy checks. The file is the seed's with
# count added; the rest is unchanged.
cat > deploy/main.tf <<'HCL'
terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "4.6.0"
    }
  }

  backend "pg" {
    conn_str = "postgres://postgres:devopslings@db:5432/app?sslmode=disable"
  }
}

provider "docker" {}

variable "image" {
  type = string
}

resource "docker_image" "shop" {
  name         = var.image
  keep_locally = true
}

resource "docker_container" "shop" {
  count = 2
  name  = "capstone-shop-${count.index + 1}"
  image = docker_image.shop.image_id

  networks_advanced {
    name         = "devopslings-ha-stack_front"
    ipv4_address = "172.29.22.3${count.index + 1}"
  }
}
HCL

git add -A
git commit -qm "deploy every commit by digest, to two replicas"
git push -q origin main
