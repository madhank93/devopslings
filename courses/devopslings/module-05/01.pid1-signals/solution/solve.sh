#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Exec form puts the app at PID 1 so docker stop's SIGTERM reaches it directly,
# instead of a /bin/sh that neither forwards nor acts on it.
set -euo pipefail

cat > Dockerfile <<'DOCKER'
FROM python:3.12-slim
WORKDIR /app
COPY app.py .
CMD ["python3", "app.py"]
DOCKER
