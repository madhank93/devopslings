#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Two halves, both required:
#   client.py   — makes one Idempotency-Key per order, before the first
#                 attempt, and sends it on every retry
#   payments.py — remembers each key it has charged and answers a replay with
#                 the original charge instead of a new one
#
# Runs on the host; the check deploys whatever is in the scratch directory.
set -euo pipefail

set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-21/*.idempotency-keys
cp "$1/solution/payments.py" "$1/solution/client.py" "$DEVOPSLINGS_ROOT/scratch/idempotency-keys/"
