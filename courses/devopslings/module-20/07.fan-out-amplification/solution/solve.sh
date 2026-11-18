#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Parallel fan-out takes the page from the sum of ten shard calls to the
# slowest of them; hedging after 30ms takes the slowest from 400ms to about
# 40ms, because the duplicate call is slow only one time in a hundred.
# Runs on the host with cwd = sandboxes/chaos-stack.
set -euo pipefail
set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-20/*.fan-out-amplification
cat > .env <<'ENV'
FANOUT=parallel
HEDGE_AFTER_MS=30
ENV
bash "$1/files/deploy.sh"
mkdir -p answers
echo "slow_page_pct=9.6" > answers/fan-out.txt
