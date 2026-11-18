#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Production's keys rather than one cached SKU, a warm-up pass that pays for
# the table load and fills the cache, and the fastest of several passes so a
# burst from the job sharing the core cannot move the number. Runs on the host
# with cwd = sandboxes/chaos-stack.
set -euo pipefail
set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-20/*.benchmark-traps
mkdir -p answers
cp "$1/solution/bench.py" answers/bench.py
