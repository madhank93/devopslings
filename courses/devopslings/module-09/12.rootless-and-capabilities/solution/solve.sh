#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# cap_drop: ALL clears the fourteen capabilities Docker grants by default as
# well as the privileged set; cap_add then puts back the single one the shaper
# actually uses.
set -euo pipefail

cat > compose.yaml <<'YAML'
services:
  shaper:
    build: .
    cap_drop:
      - ALL
    cap_add:
      - NET_ADMIN
YAML
