#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Thresholds on the error rate and p95 make k6 exit 99 on the regressed build;
# pipefail keeps that status through `| tee`, and -e stops the pipeline before
# promote. Runs on the host with cwd = sandboxes/chaos-stack.
set -euo pipefail
set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-20/*.k6-thresholds-as-a-gate
cp "$1/solution/load.js" answers/load.js
cp "$1/solution/pipeline.sh" answers/pipeline.sh
