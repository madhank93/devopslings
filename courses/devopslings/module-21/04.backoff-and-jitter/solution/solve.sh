#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Full jitter: each retry waits a random time between zero and the exponential
# delay, so clients that failed together stop retrying together. Attempts stay
# bounded but rise to eight: with six, five short draws can all land inside the
# 1s outage, and across 200 clients that happens on roughly one run in ten.
#
# Read by the load test at verify time, so no restart is needed. Runs on the
# host with cwd = sandboxes/chaos-stack.
set -euo pipefail

cat > .env <<'ENV'
RETRY_MAX_ATTEMPTS=8
RETRY_BACKOFF_MS=500
RETRY_JITTER=full
ENV
