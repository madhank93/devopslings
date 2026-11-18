#!/usr/bin/env bash
# Stage 1's starting point: ha-stack reset, the shared state and registry
# emptied, and checkout seeded with a build-only pipeline and a one-replica
# deploy that has never run. Later stages lay it down again when the student's
# stage 1 does not pass.
set -euo pipefail

api="http://127.0.0.1:3000/api/v1"
reg="http://127.0.0.1:5000"
auth="-u devops:devopslings"
accept='application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'

# ha-stack back to its starting topology, then nothing on the front
# network that ha-stack did not start itself: a replica left by an
# earlier attempt would answer at the addresses the student has to fill.
docker exec devopslings-ha-ops ha-reset
for c in $(docker ps -aq --filter network=devopslings-ha-stack_front); do
  case "$(docker inspect -f '{{.Name}}' "$c")" in
    /devopslings-ha-*) ;;
    *) docker rm -f "$c" >/dev/null ;;
  esac
done

# State from an earlier attempt would describe containers that are gone.
docker exec devopslings-ci-stack-db-1 psql -U postgres -d app -qc \
  'drop schema if exists terraform_remote_state cascade' >/dev/null

# Any protection rule left by a module-12 lesson would refuse the seed.
for rule in $(curl -fsS $auth "${api}/repos/devops/checkout/branch_protections" 2>/dev/null \
              | tr ',' '\n' | sed -n 's/.*"rule_name":"\([^"]*\)".*/\1/p' \
              | sed 's/%/%25/g; s/ /%20/g; s/\*/%2A/g; s/?/%3F/g; s/\[/%5B/g; s/]/%5D/g; s|/|%2F|g' || true); do
  curl -fsS $auth -X DELETE "${api}/repos/devops/checkout/branch_protections/${rule}" >/dev/null 2>&1 || true
done

# An empty checkout repository in the registry, so every tag the checks
# find was pushed during this attempt.
tags=$(curl -fsS "${reg}/v2/checkout/tags/list" 2>/dev/null \
         | tr ',[]' '\n\n\n' | sed -n 's/.*"\([^"]*\)".*/\1/p' \
         | grep -v '^tags$\|^name$\|^checkout$' || true)
for tag in $tags; do
  digest=$(curl -fsS -H "Accept: ${accept}" -o /dev/null -D - "${reg}/v2/checkout/manifests/${tag}" 2>/dev/null \
             | grep -i '^docker-content-digest:' | tr -d '\r' | awk '{print $2}' || true)
  [ -z "$digest" ] || curl -fsS -X DELETE "${reg}/v2/checkout/manifests/${digest}" >/dev/null 2>&1 || true
done

docker exec -i devopslings-ha-ops sh -c 'cat > /ha/haproxy.cfg' <<'CFG'
# Shared by lb1 and lb2. Production is two replicas of checkout, at the
# addresses below; the pipeline puts them there.
frontend www
    bind :80
    default_backend app

backend app
    balance roundrobin
    option httpchk GET /health
    server shop1 172.29.22.31:8080 check inter 1s fall 2 rise 2
    server shop2 172.29.22.32:8080 check inter 1s fall 2 rise 2
CFG

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git clone -q "http://devops:devopslings@127.0.0.1:3000/devops/checkout.git" "$work/checkout"
cd "$work/checkout"
git config user.email devops@example.invalid
git config user.name devops
rm -rf .forgejo .github src deploy vendor node_modules Dockerfile package.json package-lock.json
mkdir -p src deploy .forgejo/workflows

cat > src/server.js <<'JS'
const http = require("node:http");
const os = require("node:os");

const VERSION = "1.0.0";

http
  .createServer((req, res) => {
    res.setHeader("content-type", "application/json");
    if (req.url === "/health") {
      res.end(JSON.stringify({ ok: true }));
      return;
    }
    res.end(JSON.stringify({ version: VERSION, node: os.hostname() }));
  })
  .listen(8080);
JS

cat > Dockerfile <<'DOCKER'
FROM node:22-bookworm-slim
WORKDIR /app
COPY src/ ./src/
CMD ["node", "src/server.js"]
DOCKER

cat > deploy/main.tf <<'HCL'
terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "4.6.0"
    }
  }

  # State lives in ci-stack's Postgres, so every pipeline run sees what
  # the last one built. `db` resolves on the CI network only.
  backend "pg" {
    conn_str = "postgres://postgres:devopslings@db:5432/app?sslmode=disable"
  }
}

# The host's Docker daemon, through the socket a CI job mounts.
provider "docker" {}

variable "image" {
  description = "What to run, as 127.0.0.1:5000/checkout@sha256:<digest>"
  type        = string
}

resource "docker_image" "shop" {
  name         = var.image
  keep_locally = true
}

# lb1 and lb2 send traffic to 172.29.22.31 and 172.29.22.32.
resource "docker_container" "shop" {
  name  = "capstone-shop-1"
  image = docker_image.shop.image_id

  networks_advanced {
    name         = "devopslings-ha-stack_front"
    ipv4_address = "172.29.22.31"
  }
}
HCL

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
          docker build -t "${IMAGE}:latest" .
          docker push "${IMAGE}:latest"
YAML

git add -A
git commit -qm "checkout: service, image, and half a deploy"
git push -q origin main --force

echo "scenario ready"
echo
echo "  repository:  git clone http://devops:devopslings@localhost:3000/devops/checkout.git"
echo "  pipeline:    http://localhost:3000/devops/checkout/actions"
echo "  registry:    http://localhost:5000/v2/checkout/tags/list"
echo "  production:  docker exec devopslings-ha-ops curl -s http://www/"
echo
echo "www has nothing behind it yet:"
docker exec devopslings-ha-ops curl -s --max-time 3 http://www/ || echo "(no answer)"
