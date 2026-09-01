---
kind: lesson
title: "the container is unhealthy and it is serving traffic fine"
description: |
  The API answers every request and Docker says it is unhealthy, so the deploy
  never completes. Learn what a health check actually runs, the difference
  between "the process is up" and "the service is ready", and what start_period
  is for.
name: healthcheck-semantics
slug: healthcheck-semantics
createdAt: "2026-09-01"
timingSensitive: true

sandbox:
  stack: none
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 240
    run: |
      proj=devopslings-healthcheck

      cat > app.py <<'PY'
      """Price API. Serves immediately; answers prices once the cache is warm."""
      import http.server
      import socketserver
      import threading
      import time

      WARMUP_SECONDS = 10
      READY = False


      def warm():
          global READY
          time.sleep(WARMUP_SECONDS)
          READY = True
          print("price cache warm", flush=True)


      class Handler(http.server.BaseHTTPRequestHandler):
          def reply(self, code, body):
              payload = body.encode()
              self.send_response(code)
              self.send_header("Content-Type", "text/plain")
              self.send_header("Content-Length", str(len(payload)))
              self.end_headers()
              self.wfile.write(payload)

          def do_GET(self):
              if self.path == "/":
                  self.reply(200, "api v2\n")
              elif self.path in ("/ready", "/price"):
                  if READY:
                      self.reply(200, "eur:1.0842\n" if self.path == "/price" else "warm\n")
                  else:
                      self.reply(503, "warming: price cache not loaded\n")
              else:
                  self.reply(404, "not found\n")

          def log_message(self, *args):
              pass


      print("api listening on 8080, price cache warms in 10s", flush=True)
      socketserver.ThreadingTCPServer.allow_reuse_address = True
      with socketserver.ThreadingTCPServer(("", 8080), Handler) as httpd:
          threading.Thread(target=warm, daemon=True).start()
          httpd.serve_forever()
      PY

      # The health check as it was written: copied from a blog post, never run
      # against this image.
      cat > Dockerfile <<'DOCKER'
      FROM python:3.12-slim
      WORKDIR /app
      COPY app.py .
      EXPOSE 8080
      HEALTHCHECK --interval=2s --timeout=2s --retries=3 \
        CMD curl -f http://localhost:8080/ || exit 1
      CMD ["python3", "app.py"]
      DOCKER

      cat > compose.yaml <<'YAML'
      services:
        api:
          build: .
          ports:
            - "18082:8080"
      YAML

      docker compose -p "$proj" down -v --remove-orphans >/dev/null 2>&1 || true

      echo "scenario ready — files are in $(pwd)"
      echo
      echo "See it:"
      echo "  docker compose -p $proj up -d --build"
      echo "  curl -s localhost:18082/        # the app is fine"
      echo "  docker compose -p $proj ps      # docker disagrees"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 900
    run: |
      proj=devopslings-healthcheck
      port=18082

      for f in compose.yaml Dockerfile app.py; do
        if [ ! -f "$f" ]; then
          echo "not yet: no $f in $(pwd)"
          exit 1
        fi
      done

      down() { docker compose -p "$proj" down -v --remove-orphans >/dev/null 2>&1 || true; }
      trap down EXIT
      down

      if ! build_out=$(docker compose -p "$proj" build 2>&1); then
        echo "not yet: the image does not build:"
        printf '%s\n' "$build_out" | tail -12 | sed 's/^/    /'
        exit 1
      fi

      # Phase 1: does the check track readiness? Run the student's own health
      # check command by hand — once while the cache is cold and once after it is
      # warm — so the answer does not depend on how the interval was tuned.
      if ! docker compose -p "$proj" up -d >/dev/null 2>&1; then
        echo "not yet: the stack does not start — run 'docker compose -p $proj up' to see why"
        exit 1
      fi

      cid=$(docker compose -p "$proj" ps -q api 2>/dev/null || true)
      if [ -z "$cid" ]; then
        echo "not yet: no container for a service named 'api'. Keep the service name —"
        echo "the grader inspects it."
        exit 1
      fi

      test_cmd=()
      while IFS= read -r line; do
        [ -n "$line" ] && test_cmd+=("$line")
      done < <(docker inspect -f '{{range .Config.Healthcheck.Test}}{{println .}}{{end}}' "$cid" 2>/dev/null)

      if [ "${#test_cmd[@]}" -eq 0 ] || [ "${test_cmd[0]}" = "NONE" ]; then
        echo "not yet: this image has no health check. Deleting it stops the container"
        echo "being reported unhealthy and gives compose nothing to wait for —"
        echo "'up --wait' then returns before the service can answer a request."
        exit 1
      fi

      run_check() {
        if [ "${test_cmd[0]}" = "CMD-SHELL" ]; then
          docker exec "$cid" sh -c "${test_cmd[1]}" >/dev/null 2>&1
        else
          docker exec "$cid" "${test_cmd[@]:1}" >/dev/null 2>&1
        fi
      }

      # Late enough that the server is accepting connections, early enough that
      # the cache is still loading.
      sleep 3
      if run_check; then
        # Two ways to pass this early, and they are different mistakes: the check
        # is measuring the wrong thing, or the warm-up it should be waiting for
        # has been taken out of the app.
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:$port/ready" 2>/dev/null || true)
        if [ "$code" = "200" ]; then
          echo "not yet: /ready is already 200 three seconds in, so the ten-second warm-up"
          echo "is gone from app.py. The slow start is the scenario — the health check is"
          echo "the thing to change."
        else
          echo "not yet: the health check passes three seconds in, while the price cache"
          echo "is still loading and /ready is still answering $code."
          echo "It is reporting that the process is listening, not that the service is"
          echo "ready to serve. Check something that is false until the app can work."
        fi
        exit 1
      fi

      ready=""
      for _ in $(seq 40); do
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:$port/ready" 2>/dev/null || true)
        if [ "$code" = "200" ]; then ready=1; break; fi
        sleep 1
      done
      if [ -z "$ready" ]; then
        echo "not yet: /ready never returned 200 on port $port. The app has to keep"
        echo "working — the check is the thing under repair."
        exit 1
      fi

      if ! run_check; then
        echo "not yet: the app is warm and answering, and the health check still fails."
        echo "Docker runs it inside the container, where the image's own tools are all"
        echo "it has. Run it yourself and read the error:"
        if [ "${test_cmd[0]}" = "CMD-SHELL" ]; then
          echo "  docker exec ${cid%${cid#????????????}} sh -c '${test_cmd[1]}'"
        else
          echo "  docker exec ${cid%${cid#????????????}} ${test_cmd[*]:1}"
        fi
        exit 1
      fi

      # Phase 2: compose has to be able to wait on it. A check that only turns
      # healthy after the grace period it was never given makes the container
      # unhealthy first, and 'up --wait' fails there.
      down
      start=$(date +%s)
      if ! wait_out=$(docker compose -p "$proj" up -d --wait 2>&1); then
        elapsed=$(( $(date +%s) - start ))
        echo "not yet: 'up --wait' failed after ${elapsed}s:"
        printf '%s\n' "$wait_out" | tail -6 | sed 's/^/    /'
        echo "The check is right and it starts too early: the first ten seconds are a"
        echo "legitimate warm-up, the retries run out inside it, and the container is"
        echo "marked unhealthy before it ever had a chance."
        exit 1
      fi
      elapsed=$(( $(date +%s) - start ))

      if [ "$elapsed" -lt 6 ]; then
        echo "not yet: 'up --wait' returned in ${elapsed}s, and the cache takes ten"
        echo "seconds to warm. Either the check is passing before the app is ready or"
        echo "the warm-up itself was shortened — the app is not the thing to change."
        exit 1
      fi

      status=$(docker inspect -f '{{.State.Health.Status}}' "$(docker compose -p "$proj" ps -q api)" 2>/dev/null || true)
      if [ "$status" != "healthy" ]; then
        echo "not yet: 'up --wait' returned 0 and the container is '$status'"
        exit 1
      fi

      price=$(curl -s --max-time 3 "http://127.0.0.1:$port/price" 2>/dev/null || true)
      if [ "$price" != "eur:1.0842" ]; then
        echo "not yet: the stack is healthy and /price says '${price:-nothing}'."
        echo "Healthy has to mean the service can do its job."
        exit 1
      fi

      echo "PASS — the check is false while the cache loads and true once it is warm,"
      echo "and 'up --wait' blocked ${elapsed}s and returned a service that serves."
---
