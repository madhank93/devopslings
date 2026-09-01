#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Two changes: the check asks the readiness endpoint rather than the static
# route, using the image's own python because there is no curl in it; and
# start-period gives the warm-up room so the retries do not run out inside it.
set -euo pipefail

cat > Dockerfile <<'DOCKER'
FROM python:3.12-slim
WORKDIR /app
COPY app.py .
EXPOSE 8080
HEALTHCHECK --interval=2s --timeout=3s --retries=3 --start-period=30s \
  CMD ["python3", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:8080/ready').read()"]
CMD ["python3", "app.py"]
DOCKER
