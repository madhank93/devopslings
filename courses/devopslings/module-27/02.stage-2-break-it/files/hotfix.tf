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
  env   = ["PAYMENTS=disabled"]

  networks_advanced {
    name         = "devopslings-ha-stack_front"
    ipv4_address = "172.29.22.3${count.index + 1}"
  }
}
