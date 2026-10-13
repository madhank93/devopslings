#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Priority shedding: recommendations are refused on arrival once 6 requests
# are in flight, so the queue a checkout joins is never more than a few deep.
# Checkout is never shed — on its own it uses well under half of capacity.
#
# api is redeployed from .env when the check runs. Runs on the host with
# cwd = sandboxes/chaos-stack.
set -euo pipefail

cat > .env <<'ENV'
API_WORKERS=16
QUEUE_TIMEOUT_MS=0
SHED_ALL_AT=0
SHED_LOW_AT=6
ENV
