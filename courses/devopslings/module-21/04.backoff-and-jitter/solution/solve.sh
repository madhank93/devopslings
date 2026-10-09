#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# One change: full jitter. Each retry waits a random time between zero and the
# exponential delay, so clients that failed together stop retrying together.
# Attempts stay bounded; six covers a 1s outage even when the random delays
# come out short.
#
# Read by the load test at verify time, so no restart is needed. Runs on the
# host with cwd = sandboxes/chaos-stack.
set -euo pipefail

cat > .env <<'ENV'
RETRY_MAX_ATTEMPTS=6
RETRY_BACKOFF_MS=500
RETRY_JITTER=full
ENV
