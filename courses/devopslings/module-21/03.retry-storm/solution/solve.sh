#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
#   RETRY_ON without 4xx — a 404 is an answer; retrying it is pure load
#   RETRY_BUDGET=0.1     — retries may add at most ~10% to pricing's traffic,
#                          however many requests are failing at once
#   RETRY_MAX_ATTEMPTS=3 — still bounds the latency of any one request
#
# The policy is read when inject_fault starts checkout-retry, so no restart is
# needed. Runs on the host with cwd = sandboxes/chaos-stack.
set -euo pipefail

cat > .env <<'ENV'
RETRY_MAX_ATTEMPTS=3
RETRY_ON=connect,timeout,5xx
RETRY_BUDGET=0.1
ENV
