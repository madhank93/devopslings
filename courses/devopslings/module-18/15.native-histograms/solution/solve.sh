#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The SDK sends an exponential histogram, and prometheus-2 accepts native
# histograms. Both ends, or nothing changes.
set -euo pipefail
sed -i 's/ExplicitBucketHistogramAggregation(\[0.05, 0.1, 0.25, 0.5, 1, 2.5\])/ExponentialBucketHistogramAggregation()/
        s/import ExplicitBucketHistogramAggregation, View/import ExponentialBucketHistogramAggregation, View/' /obs/apps/lab.py
grep -q 'enable-feature=native-histograms' /obs/prometheus-2/run.sh ||
  sed -i 's|--web.enable-otlp-receiver$|--web.enable-otlp-receiver \\\n  --enable-feature=native-histograms|' /obs/prometheus-2/run.sh
