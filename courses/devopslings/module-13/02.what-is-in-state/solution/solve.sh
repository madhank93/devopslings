#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail
cd /root/app

# Same container, new address.
tofu state mv docker_container.app docker_container.api
# Still running, no longer ours.
tofu state rm docker_container.legacy

tofu plan -detailed-exitcode -input=false
