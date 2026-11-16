#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail
cd /root/platform

cat > backend.tf <<'TF'
terraform {
  backend "s3" {
    bucket = "tofu-state"
    key    = "platform/terraform.tfstate"
    region = "us-east-1"
    endpoints = {
      s3 = "http://minio:9000"
    }
    use_path_style              = true
    use_lockfile                = true
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
  }
}
TF

# Copies the local state into MinIO; -force-copy answers the prompt.
tofu init -input=false -migrate-state -force-copy
tofu plan -input=false -detailed-exitcode

printf '.terraform/\n*.tfstate\n*.tfstate.*\n' > .gitignore
git rm -q --cached terraform.tfstate
git add .gitignore backend.tf
git commit -qm "Keep state in MinIO, not in git"
