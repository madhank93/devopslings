#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail
cd /root/svc

cat > main.tf <<'TF'
resource "docker_container" "svc" {
  for_each = toset(var.services)

  name    = "svc-${each.key}"
  image   = "busybox:1.37.0"
  restart = "unless-stopped"
  command = ["sh", "-c", "echo ${each.key} > /www/index.html; exec httpd -f -p 8080 -h /www"]
}

# The containers that stay keep their identity under the new keys. svc[1]
# (billing) has no new address, so it is destroyed.
moved {
  from = docker_container.svc[0]
  to   = docker_container.svc["auth"]
}

moved {
  from = docker_container.svc[2]
  to   = docker_container.svc["search"]
}
TF

cat > terraform.tfvars <<'TF'
services = ["auth", "search"]
TF

tofu apply -auto-approve -input=false
