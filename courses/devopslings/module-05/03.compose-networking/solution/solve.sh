#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Container-to-container traffic uses the compose network: the service name
# `cache`, and the port Redis actually listens on (6379), not the published
# host port. The `ports:` mapping on cache is removed because it was never
# involved in this path and publishing a datastore is a needless exposure.
set -euo pipefail

cat > compose.yaml <<'YAML'
services:
  api:
    build: .
    ports:
      - "18081:8080"
    environment:
      REDIS_URL: "redis://cache:6379"
    depends_on:
      cache:
        condition: service_healthy

  cache:
    image: redis:7-alpine
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 2s
      retries: 10
YAML
