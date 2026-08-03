#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Two independent changes, both required:
#   timeout  — bounds how long a slow dependency can hold a worker, which is
#              what stops the cascade
#   fallback — keeps answering customers, because a fast 503 clears the latency
#              threshold and still fails the checks threshold
#
# Runs on the host with cwd = sandboxes/chaos-stack.
set -euo pipefail

cat > .env <<'ENV'
PRICING_CONNECT_TIMEOUT=1
PRICING_READ_TIMEOUT=2
PRICING_FALLBACK=39.99
ENV

# Compose reads .env at container-create time, so the config only takes effect
# after a recreate.
docker compose up -d
