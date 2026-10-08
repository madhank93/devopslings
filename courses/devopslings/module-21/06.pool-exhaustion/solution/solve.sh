#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# A bulkhead: at most 8 of shop's 16 threads may be inside a pricing call, so
# the other 8 always remain for /browse. No timeout is needed for this fault —
# pricing answers in 1.5s, and an excess checkout is refused instantly rather
# than waiting for a slot.
#
# Runs on the host with cwd = sandboxes/chaos-stack.
set -euo pipefail

L=../../courses/devopslings/module-21/06.pool-exhaustion
cat > .env <<ENV
COMPOSE_FILE=compose.yaml:$L/shop.compose.yaml
SHOP_THREADS=16
PRICING_TIMEOUT=0
PRICING_POOL=8
ENV

docker compose -f compose.yaml -f "$L/shop.compose.yaml" up -d --wait shop
