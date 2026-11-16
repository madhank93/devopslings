#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail
cd /root/envs
install -d modules/shop

cat > modules/shop/main.tf <<'TF'
terraform {
  required_providers {
    docker = {
      source = "kreuzwerker/docker"
    }
  }
}

variable "env" {
  type = string
}

variable "restart" {
  type    = string
  default = "unless-stopped"
}

resource "docker_network" "net" {
  name = "shop-${var.env}"
}

resource "docker_volume" "data" {
  name = "shop-${var.env}-data"
}

resource "docker_container" "app" {
  name    = "shop-${var.env}"
  image   = "busybox:1.37.0"
  restart = var.restart
  env     = ["SHOP_ENV=${var.env}"]
  command = ["sh", "-c", "echo shop $SHOP_ENV > /www/index.html; exec httpd -f -p 8080 -h /www"]
  networks_advanced {
    name = docker_network.net.name
  }
  volumes {
    volume_name    = docker_volume.data.name
    container_path = "/data"
  }
}

output "endpoint" {
  value = "http://${docker_container.app.name}:8080"
}
TF

{
  cat <<'TF'
locals {
  restart = {
    dev     = "unless-stopped"
    test    = "unless-stopped"
    staging = "unless-stopped"
    prod    = "always"
  }
}

module "shop" {
  source   = "./modules/shop"
  for_each = local.restart

  env     = each.key
  restart = each.value
}
TF
  for e in dev test staging prod; do
    for p in "net docker_network" "data docker_volume" "app docker_container"; do
      set -- $p
      printf '\nmoved {\n  from = %s.%s_%s\n  to   = module.shop["%s"].%s.%s\n}\n' "$2" "$e" "$1" "$e" "$2" "$1"
    done
  done
} > main.tf

cat > outputs.tf <<'TF'
output "endpoints" {
  value = { for env, m in module.shop : env => m.endpoint }
}
TF

tofu init -input=false
tofu apply -auto-approve -input=false
