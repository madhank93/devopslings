#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail
cd /root/web

cat > main.tf <<'TF'
resource "docker_container" "web" {
  name    = "web"
  image   = "busybox:1.37.0"
  restart = "unless-stopped"
  env     = ["GREETING=hello", "PORT=8080"]
  command = ["sh", "-c", "echo \"$GREETING from web\" > /www/index.html; exec httpd -f -p \"$PORT\" -h /www"]
}
TF

# OpenTofu will not adopt a container it did not create; the hand-made one
# holds the name, so it goes.
docker rm -f web >/dev/null
tofu init -input=false
tofu apply -auto-approve -input=false
