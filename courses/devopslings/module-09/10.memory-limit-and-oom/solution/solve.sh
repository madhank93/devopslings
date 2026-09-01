#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The live set is about 650 MB, so 512m was never going to hold it. The limit
# goes to the budget, and the heap ceiling goes below the limit by enough for
# everything a JVM keeps outside the heap — which is what makes an overrun an
# OutOfMemoryError instead of a kill.
set -euo pipefail

cat > compose.yaml <<'YAML'
services:
  aggregator:
    build: .
    mem_limit: 1g
    environment:
      RECORDS: "8000000"
      JDK_JAVA_OPTIONS: "-Xmx700m"
YAML
