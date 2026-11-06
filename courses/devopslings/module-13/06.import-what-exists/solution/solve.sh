#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail
cd /root/payments

# Every attribute the objects were created with, or the plan replaces them.
cat > main.tf <<'TF'
import {
  to = docker_network.payments
  id = "payments-net"
}

import {
  to = docker_volume.ledger
  id = "ledger"
}

resource "docker_network" "payments" {
  name     = "payments-net"
  driver   = "bridge"
  internal = true

  ipam_config {
    subnet  = "10.42.0.0/24"
    gateway = "10.42.0.1"
  }

  labels {
    label = "team"
    value = "payments"
  }
  labels {
    label = "tier"
    value = "data"
  }
}

resource "docker_volume" "ledger" {
  name = "ledger"

  labels {
    label = "team"
    value = "payments"
  }
  labels {
    label = "backup"
    value = "nightly"
  }
}
TF

# Refuse to apply anything but the two imports.
tofu plan -input=false -no-color -out=import.plan > import.log
cat import.log
grep -q 'Plan: 2 to import, 0 to add, 0 to change, 0 to destroy' import.log
tofu apply -input=false import.plan
rm -f import.plan import.log
