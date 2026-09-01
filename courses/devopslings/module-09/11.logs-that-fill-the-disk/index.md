---
kind: lesson
title: "nothing is broken and the host runs out of disk every Thursday"
description: |
  The service is healthy, the code has not changed, and /var fills up week
  after week. Learn where a container's stdout actually goes, why deleting that
  file frees nothing, and how to bound it without going blind.
name: logs-that-fill-the-disk
slug: logs-that-fill-the-disk
createdAt: "2026-09-01"

sandbox:
  stack: none
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      proj=devopslings-logs

      cat > app.sh <<'SH'
      #!/bin/sh
      # quote-api, replaying a day of production traffic. Every request is logged
      # at debug level, headers and all, because that is what was needed once.
      awk 'BEGIN {
        for (i = 1; i <= 200000; i++)
          printf "{\"ts\":\"2026-09-01T00:00:00Z\",\"level\":\"debug\",\"req\":%d,\"path\":\"/api/v1/quote\",\"headers\":\"accept=application/json; user-agent=checkout-service/2.4.1; x-request-id=00000000-0000-0000-0000-%012d\"}\n", i, i;
      }'
      echo "replayed 200000 requests"
      SH
      chmod +x app.sh

      cat > Dockerfile <<'DOCKER'
      FROM alpine:3.20
      COPY app.sh /app.sh
      CMD ["/app.sh"]
      DOCKER

      cat > compose.yaml <<'YAML'
      services:
        quote-api:
          build: .
      YAML

      docker compose -p "$proj" down -v --remove-orphans >/dev/null 2>&1 || true
      docker image rm -f devopslings-logs-probe >/dev/null 2>&1 || true

      echo "scenario ready — files are in $(pwd)"
      echo
      echo "See it:"
      echo "  docker compose -p $proj up -d --build && docker compose -p $proj wait quote-api"
      echo "  docker logs \$(docker compose -p $proj ps -aq quote-api) | wc -c"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 600
    run: |
      proj=devopslings-logs
      probe=devopslings-logs-probe
      floor=31457280   # 30 MiB — what one replay must still emit
      ceiling=8388608  # 8 MiB — what may still be on disk afterwards

      # Sizes read back in whichever unit does not round to zero.
      human() {
        if [ "$1" -ge 1048576 ]; then echo "$(( $1 / 1048576 ))MB"; else echo "$(( $1 / 1024 ))KB"; fi
      }

      cleanup() {
        docker rm -f "$probe" >/dev/null 2>&1 || true
        docker image rm -f "$probe" >/dev/null 2>&1 || true
      }
      trap cleanup EXIT
      cleanup

      for f in app.sh Dockerfile compose.yaml; do
        if [ ! -f "$f" ]; then
          echo "not yet: no $f in $(pwd)"
          exit 1
        fi
      done

      # How much the service actually emits, measured from the same image with no
      # log options at all. Quieting the service would fix the disk and lose the
      # logs, so this is checked before anything else.
      if ! docker build -q -t "$probe" . >/dev/null 2>&1; then
        echo "not yet: the image does not build — run 'docker build .' to see why"
        exit 1
      fi
      docker run -d --name "$probe" "$probe" >/dev/null
      docker wait "$probe" >/dev/null
      emitted=$(docker logs "$probe" 2>/dev/null | wc -c | tr -d ' ')

      if [ "${emitted:-0}" -lt "$floor" ]; then
        echo "not yet: one replay now emits $(human "$emitted"), and it used to emit"
        echo "about 40MB. Turning the service down is a different change with different"
        echo "consequences — this exercise is about what the daemon does with the"
        echo "output, not about how much of it there is."
        exit 1
      fi

      docker compose -p "$proj" down -v --remove-orphans >/dev/null 2>&1 || true
      if ! up_out=$(docker compose -p "$proj" up -d --build 2>&1); then
        echo "not yet: the stack does not come up:"
        printf '%s\n' "$up_out" | tail -10 | sed 's/^/    /'
        exit 1
      fi

      cid=$(docker compose -p "$proj" ps -aq quote-api 2>/dev/null || true)
      if [ -z "$cid" ]; then
        echo "not yet: no container for a service named 'quote-api'. Keep the service"
        echo "name — the grader reads its logs."
        exit 1
      fi
      docker wait "$cid" >/dev/null 2>&1 || true

      driver=$(docker inspect -f '{{.HostConfig.LogConfig.Type}}' "$cid" 2>/dev/null || true)
      if [ "$driver" = "none" ]; then
        echo "not yet: the log driver is 'none'. That does bound the disk, by throwing"
        echo "every line away as it is written: 'docker logs' returns nothing, and the"
        echo "next incident is debugged without them. Keep the logs, bound them."
        exit 1
      fi

      if ! retained=$(docker logs "$cid" 2>/dev/null | wc -c | tr -d ' '); then
        echo "not yet: 'docker logs' cannot read this container's logs. The '$driver'"
        echo "driver does not support reading them back, which is a different trade"
        echo "than the one this exercise is asking for."
        exit 1
      fi

      if [ "${retained:-0}" -gt "$ceiling" ]; then
        echo "not yet: the service emitted $(human "$emitted") and $(human "$retained") of it is"
        echo "still on disk. Multiply that by a week of real traffic and by every"
        echo "container on the host. The daemon writes stdout to a file and, by"
        echo "default, never stops."
        exit 1
      fi

      # Bounded and readable are both required: rotation keeps the newest, so the
      # line the service finished on has to survive.
      if ! docker logs "$cid" 2>/dev/null | tail -5 | grep -q 'replayed 200000 requests'; then
        echo "not yet: the log is bounded at $(human "$retained") and the last thing the service"
        echo "said is not in it. Rotation keeps the newest output — if the end is"
        echo "missing, what is kept is not the part you would want during an incident."
        exit 1
      fi

      echo "PASS — $(human "$emitted") emitted, $(human "$retained") retained, and the last line"
      echo "the service wrote is still readable with 'docker logs'."
---
