#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Contain the fault at the hop where it enters: product -> reviews.
#   PRODUCT_TO_REVIEWS_POOL=4      reviews may hold at most 4 of product's 8
#                                  threads; the rest serve /stock and pages
#   PRODUCT_TO_REVIEWS_TIMEOUT=0.6 above the normal 300ms tail, so a slow call
#                                  gives its slot back instead of holding it 3s
# The hops above product need nothing: product never stops answering them.
#
# The services are redeployed from .env when the check runs. Runs on the host
# with cwd = sandboxes/chaos-stack.
set -euo pipefail

cat > .env <<'ENV'
GATEWAY_TO_PRODUCT_TIMEOUT=0
GATEWAY_TO_PRODUCT_POOL=0
GATEWAY_TO_ORDERS_TIMEOUT=0
GATEWAY_TO_ORDERS_POOL=0
ORDERS_TO_PRODUCT_TIMEOUT=0
ORDERS_TO_PRODUCT_POOL=0
PRODUCT_TO_REVIEWS_TIMEOUT=0.6
PRODUCT_TO_REVIEWS_POOL=4
ENV
