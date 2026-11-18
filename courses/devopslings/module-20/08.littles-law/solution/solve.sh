#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# L = λW: 150 arrivals a second × 0.2s each = 30 renders in progress on
# average. 38 workers runs them about 80% busy, which absorbs bursts.
# Runs on the host with cwd = sandboxes/chaos-stack.
set -euo pipefail
set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-20/*.littles-law
echo "WORKERS=38" > .env
bash "$1/files/deploy.sh"
mkdir -p answers
printf 'service_time_ms=200\nworkers_needed=30\n' > answers/littles-law.txt
