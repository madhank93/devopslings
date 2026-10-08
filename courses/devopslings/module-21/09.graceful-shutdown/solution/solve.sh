#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Replaces the student's app.py with one that shuts down in the right order:
# flip /ready to 503, keep serving until the balancer has stopped routing here,
# stop accepting, wait for in-flight requests, exit.
#
# Runs on the host with cwd = sandboxes/chaos-stack.
set -euo pipefail

L=../../courses/devopslings/module-21/09.graceful-shutdown
cp "$L/solution/app.py" ../../scratch/graceful-shutdown/app.py

# The running replicas loaded the old code at start.
docker compose -f compose.yaml -f "$L/graceful.compose.yaml" \
  up -d --wait --force-recreate orders-a orders-b probe
