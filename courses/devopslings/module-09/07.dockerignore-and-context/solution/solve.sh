#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# .dockerignore is read by the client before anything is uploaded, so what it
# excludes is never sent. Narrowing the COPY lines would not have helped: the
# context is assembled before the Dockerfile is read.
set -euo pipefail

cat > .dockerignore <<'IGNORE'
.git
**/node_modules
.venv
fixtures
tmp
*.log
IGNORE
