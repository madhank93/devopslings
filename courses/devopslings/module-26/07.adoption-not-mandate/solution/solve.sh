#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Per team and stage, the golden path's average stage time against the team's
# own pipeline: deps is 960s against 45s for data, 1140s against 50s for
# mobile. Cache dependencies on the golden path; leave approval and mandate alone.
set -euo pipefail
sed -i 's/cache: false .*/cache: true         # restore dependencies from a cache keyed on the lockfile/' /obs/platform/golden-path.yml
mkdir -p /obs/answers
cat > /obs/answers/adoption.txt <<'TXT'
stage: deps
evidence: sum by (team, pipeline) (rate(ci_pipeline_stage_duration_seconds_sum{stage="deps",team=~"data|mobile"}[5m])) / sum by (team, pipeline) (rate(ci_pipeline_stage_duration_seconds_count{stage="deps",team=~"data|mobile"}[5m]))
change: stages.deps.cache true: their dependency trees take 16-19 minutes to install fresh, and under a minute from cache, which is what their own pipelines do.
TXT
