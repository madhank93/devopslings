#!/usr/bin/env bash
# Before every check: Prometheus back on the front network and scraping both
# load balancers. Nothing the student owns is touched.
set -euo pipefail
. "$DEVOPSLINGS_ROOT/courses/devopslings/module-27/files/lib.sh"
. "$DEVOPSLINGS_ROOT/courses/devopslings/module-27/03.stage-3-hold-the-line/files/common.sh"
docker rm -f capstone-k6 >/dev/null 2>&1 || true
prom_up
echo "Prometheus is scraping lb1 and lb2; the experiment starts with the check"
