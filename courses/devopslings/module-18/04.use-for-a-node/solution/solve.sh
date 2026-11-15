#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The saturated resource is db's connection pool, not CPU:
#   utilisation  connections checked out, as a fraction of the pool
#   saturation   queries queued for a connection
#   errors       queries refused because none came free, per second
set -euo pipefail
cd /obs/queries
echo 'avg_over_time(db_pool_connections_in_use[30s]) / db_pool_connections_max' > use-utilisation.promql
echo 'avg_over_time(db_pool_waiting_queries[30s])' > use-saturation.promql
echo 'rate(db_pool_acquire_timeouts_total[30s])' > use-errors.promql
