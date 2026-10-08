#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Both timeouts set explicitly: leaving either at 0 makes checkout fill it in
# as 3s, and 3s plus anything is over the 3s budget. connect + read = 3.
#
# Runs on the host with cwd = sandboxes/chaos-stack.
set -euo pipefail

cat > .env <<'ENV'
PRICING_CONNECT_TIMEOUT=1
PRICING_READ_TIMEOUT=2
PRICING_FALLBACK=
ENV

# Compose reads .env at container-create time, so the config only takes effect
# after a recreate.
docker compose up -d --wait

mkdir -p "$DEVOPSLINGS_ROOT/scratch/set-a-timeout"
cat > "$DEVOPSLINGS_ROOT/scratch/set-a-timeout/answer.txt" <<'ANS'
fired: read
worst_case: 3
ANS
