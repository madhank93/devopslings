#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Single-flight: one lock per key, so when a product expires one request
# reloads it and the others wait for that load instead of making their own.
# Runs on the host with cwd = sandboxes/chaos-stack.
set -euo pipefail
set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-20/*.cache-stampede
cp "$1/solution/cache.py" answers/cache.py
