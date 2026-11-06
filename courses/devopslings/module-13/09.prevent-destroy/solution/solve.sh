#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail
cd /root/db

# The guard goes on what holds data; containers stay replaceable.
sed -i 's/^  name = "db-data"$/  name = "db-data"\n\n  lifecycle {\n    prevent_destroy = true\n  }/' main.tf
sed -i 's/RELEASE=1/RELEASE=2/' main.tf

tofu apply -auto-approve -input=false
