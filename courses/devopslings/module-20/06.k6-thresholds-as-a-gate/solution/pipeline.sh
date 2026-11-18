#!/usr/bin/env bash
# The cart pipeline, after build and unit tests. Run from sandboxes/chaos-stack;
# the candidate build is already on staging (checkout:8210).
set -euo pipefail

echo "== stage: load test =="
docker compose exec -T k6 k6 run - < answers/load.js | tee answers/load-test.log

echo "== stage: promote =="
date +%s > answers/promoted
echo "promoted the candidate to production"
