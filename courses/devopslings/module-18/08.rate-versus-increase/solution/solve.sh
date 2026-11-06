#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# increase() per series first, so each worker's restart is handled as a reset of
# its own counter, then sum the workers.
set -euo pipefail
echo 'sum(increase(worker_jobs_processed_total[5m]))' > /obs/queries/jobs-last-5m.promql
