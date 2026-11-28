#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# From a tools container in the target's network namespace:
#   docker run --rm --network=container:quote-api busybox:1.37 netstat -ltn
# shows 0.0.0.0:8081 (health) and 127.0.0.1:8080 (api). "localhost" in the
# config resolved to loopback, which published-port traffic never reaches.
# Runs on the host with cwd = scratch/debug-a-distroless-container.
set -euo pipefail
mkdir -p answers
echo "listening=127.0.0.1:8080" > answers/distroless.txt
docker run --rm -v quote-api-config:/c busybox:1.37 \
  sed -i 's/^listen = localhost:8080$/listen = 0.0.0.0:8080/' /c/app.ini
docker restart quote-api >/dev/null
for _ in $(seq 1 40); do
  curl -fsS -m 2 http://127.0.0.1:18430/quote >/dev/null 2>&1 && break
  sleep 0.5
done
