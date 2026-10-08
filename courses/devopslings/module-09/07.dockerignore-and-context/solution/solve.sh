#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# .dockerignore bounds the context itself, whatever any COPY line asks for and
# whichever builder reads it; narrowing COPY only trims what one Dockerfile pulls.
set -euo pipefail

cat > .dockerignore <<'IGNORE'
.git
**/node_modules
.venv
fixtures
tmp
*.log
IGNORE
