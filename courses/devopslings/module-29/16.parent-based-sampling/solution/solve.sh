#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# ledger samples on its own trace-id ratio and ignores the sampled flag in the
# traceparent it receives. ParentBased follows the parent when there is one and
# falls back to the ratio only for requests that arrive with no trace.
set -euo pipefail
sed -i \
  -e 's/^from opentelemetry.sdk.trace.sampling import TraceIdRatioBased$/from opentelemetry.sdk.trace.sampling import ParentBased, TraceIdRatioBased/' \
  -e 's/sampler=TraceIdRatioBased(0.5)/sampler=ParentBased(TraceIdRatioBased(0.5))/' \
  /obs/apps/ledger.py
grep -q 'sampler=ParentBased(TraceIdRatioBased(0.5))' /obs/apps/ledger.py
