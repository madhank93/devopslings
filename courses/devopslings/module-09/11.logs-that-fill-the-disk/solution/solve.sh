#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The json-file driver never rotates unless told to. max-size caps one file and
# max-file caps how many are kept, so the ceiling is the product of the two, and
# the newest output is what survives.
set -euo pipefail

cat > compose.yaml <<'YAML'
services:
  quote-api:
    build: .
    logging:
      driver: json-file
      options:
        max-size: "1m"
        max-file: "3"
YAML
