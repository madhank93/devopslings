#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Two independent fixes to one Dockerfile:
#   size  — slim base + multi-stage, so the compile toolchain is discarded
#   cache — copy requirements.txt and install before copying the source, so a
#           source edit cannot invalidate the dependency layer
set -euo pipefail

cat > Dockerfile <<'DOCKER'
FROM python:3.12-slim AS builder
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.12-slim
WORKDIR /app
COPY --from=builder /install /usr/local
COPY app.py .
CMD ["python3", "app.py"]
DOCKER

cat > .dockerignore <<'IGNORE'
__pycache__/
*.pyc
.git/
IGNORE
