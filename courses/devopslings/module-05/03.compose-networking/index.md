---
kind: lesson
title: "The API can't reach Redis, and both containers are healthy"
description: |
  Two services on one compose network. Both are up. The API gets connection
  refused every time. Learn what `localhost` means inside a container, what
  compose service names resolve to, and why publishing a port did not help.
name: compose-networking
slug: compose-networking
createdAt: "2026-07-31"

sandbox:
  stack: none
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 120
    run: |
      cat > app.py <<'PY'
      import os, sys
      from flask import Flask
      import redis

      REDIS_URL = os.environ.get("REDIS_URL", "redis://localhost:6379")

      app = Flask(__name__)
      r = redis.Redis.from_url(REDIS_URL, socket_connect_timeout=2)

      @app.get("/health")
      def health():
          try:
              r.ping()
          except Exception as e:
              return {"status": "degraded", "redis": REDIS_URL, "error": str(e)}, 503
          return {"status": "ok", "redis": REDIS_URL}

      @app.get("/hits")
      def hits():
          return {"hits": r.incr("hits")}

      if __name__ == "__main__":
          print(f"api starting, redis={REDIS_URL}", flush=True)
          app.run(host="0.0.0.0", port=8080)
      PY

      cat > requirements.txt <<'REQ'
      flask==3.0.3
      redis==5.0.8
      REQ

      cat > Dockerfile <<'DOCKER'
      FROM python:3.12-slim
      WORKDIR /app
      COPY requirements.txt .
      RUN pip install --no-cache-dir -r requirements.txt
      COPY app.py .
      CMD ["python3", "app.py"]
      DOCKER

      # The compose file as first written. Redis is published to the host, the
      # API points at localhost, and someone has concluded that "it's on the
      # same network so it should just work".
      cat > compose.yaml <<'YAML'
      services:
        api:
          build: .
          ports:
            - "18081:8080"
          environment:
            REDIS_URL: "redis://localhost:6379"
          depends_on:
            - cache

        cache:
          image: redis:7-alpine
          ports:
            - "16379:6379"
      YAML

      docker compose -p devopslings-netlab down -v --remove-orphans >/dev/null 2>&1 || true
      docker compose -p devopslings-netlab up -d --build >/dev/null 2>&1 || true

      echo "scenario ready — files are in $(pwd)"
      echo
      echo "See it fail:"
      echo "  curl -s localhost:18081/health"
      echo "  docker compose -p devopslings-netlab logs api"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 600
    run: |
      proj=devopslings-netlab

      if [ ! -f compose.yaml ]; then
        echo "not yet: no compose.yaml in $(pwd)"
        exit 1
      fi

      # Rebuild from the student's files, from scratch, so a container that
      # happens to be running with hand-patched state cannot pass.
      docker compose -p "$proj" down -v --remove-orphans >/dev/null 2>&1 || true
      if ! docker compose -p "$proj" up -d --build >/dev/null 2>&1; then
        echo "not yet: the stack does not come up — run 'docker compose -p $proj up --build' to see why"
        exit 1
      fi

      ok=""
      body=""
      for _ in $(seq 30); do
        body=$(curl -fsS --max-time 2 http://127.0.0.1:18081/health 2>/dev/null || true)
        if printf '%s' "$body" | grep -q '"ok"'; then ok=1; break; fi
        sleep 1
      done

      if [ -z "$ok" ]; then
        last=$(curl -s --max-time 2 http://127.0.0.1:18081/health 2>/dev/null || true)
        echo "not yet: /health is not ok — ${last:-no response}"
        exit 1
      fi

      # Reaching Redis at all is not enough: it has to be reached over the
      # compose network. A student who published the port and pointed the API at
      # host.docker.internal has made it work by routing container -> host ->
      # container, which breaks the moment this runs anywhere but a laptop.
      url=$(printf '%s' "$body" | sed -n 's/.*"redis":"\([^"]*\)".*/\1/p')
      case "$url" in
        *localhost*|*127.0.0.1*|*host.docker.internal*)
          echo "not yet: the API is reaching Redis via '$url' — that leaves the container network. Use the service's name on the compose network."
          exit 1
          ;;
      esac

      # And it must actually be usable, not just answer a ping.
      h1=$(curl -fsS --max-time 3 http://127.0.0.1:18081/hits 2>/dev/null || true)
      h2=$(curl -fsS --max-time 3 http://127.0.0.1:18081/hits 2>/dev/null || true)
      if [ -z "$h2" ] || [ "$h1" = "$h2" ]; then
        echo "not yet: /hits did not increment — the API answers but is not really talking to Redis"
        exit 1
      fi

      echo "PASS — the API reaches Redis at '$url' over the compose network, and writes land."
---
