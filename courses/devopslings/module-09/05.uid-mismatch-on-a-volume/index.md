---
kind: lesson
title: "the summarizer stopped writing the day it stopped running as root"
description: |
  A security review asked for the container to run as a non-root user. It now
  exits with Permission denied on a volume it has always written to. Learn who
  owns a named volume, why the first container to touch it decides that, and
  why chmod 777 is not the answer.
name: uid-mismatch-on-a-volume
slug: uid-mismatch-on-a-volume
createdAt: "2026-08-31"

sandbox:
  stack: none
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 240
    run: |
      proj=devopslings-uid-mismatch

      cat > summarize.py <<'PY'
      #!/usr/bin/env python3
      """Summarise the exporter's events into a report on the shared volume."""
      import json
      import os

      SRC = "/data/incoming/events.jsonl"
      OUT = "/data/out/summary.txt"

      print(f"running as uid {os.getuid()}", flush=True)

      with open(SRC) as f:
          events = [json.loads(line) for line in f if line.strip()]

      errors = sum(1 for e in events if e["level"] == "error")

      os.makedirs(os.path.dirname(OUT), exist_ok=True)
      with open(OUT, "w") as f:
          f.write(f"events: {len(events)}\n")
          f.write(f"errors: {errors}\n")

      print(f"wrote {OUT}", flush=True)
      PY

      # The image the security review produced: same app, no longer root.
      cat > Dockerfile <<'DOCKER'
      FROM python:3.12-slim
      RUN useradd --uid 10001 --create-home appuser
      WORKDIR /app
      COPY summarize.py .
      USER appuser
      CMD ["python3", "summarize.py"]
      DOCKER

      # exporter is a vendor image and runs as root. summarizer used to as well,
      # and nobody had a reason to think about who owned the volume.
      cat > compose.yaml <<'YAML'
      services:
        exporter:
          image: alpine:3.20
          command:
            - sh
            - -c
            - |
              mkdir -p /data/incoming
              printf '%s\n' \
                '{"level":"info","msg":"start"}' \
                '{"level":"error","msg":"timeout"}' \
                '{"level":"info","msg":"done"}' \
                '{"level":"error","msg":"refused"}' \
                '{"level":"info","msg":"idle"}' \
                > /data/incoming/events.jsonl
              echo "exported 5 events"
          volumes:
            - reports:/data

        summarizer:
          build: .
          depends_on:
            exporter:
              condition: service_completed_successfully
          volumes:
            - reports:/data

      volumes:
        reports:
      YAML

      docker compose -p "$proj" down -v --remove-orphans >/dev/null 2>&1 || true

      echo "scenario ready — files are in $(pwd)"
      echo
      echo "See it fail:"
      echo "  docker compose -p $proj up --build"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 600
    run: |
      proj=devopslings-uid-mismatch

      for f in compose.yaml Dockerfile summarize.py; do
        if [ ! -f "$f" ]; then
          echo "not yet: no $f in $(pwd)"
          exit 1
        fi
      done

      # Every run starts from an empty volume, because ownership of a named
      # volume is decided the first time something writes to it. A fix that only
      # works against the volume left over from the last attempt is not a fix.
      docker compose -p "$proj" down -v --remove-orphans >/dev/null 2>&1 || true

      if ! out=$(docker compose -p "$proj" up --build --exit-code-from summarizer 2>&1); then
        echo "not yet: the stack came up and summarizer did not exit 0."
        if printf '%s' "$out" | grep -q 'Permission denied'; then
          echo "It is still being refused by the filesystem:"
          printf '%s' "$out" | grep -m3 'Permission denied' | sed 's/^/    /'
          echo "Who owns /data, and who is asking to write to it?"
        else
          printf '%s' "$out" | tail -15 | sed 's/^/    /'
        fi
        exit 1
      fi

      cid=$(docker compose -p "$proj" ps -a -q summarizer 2>/dev/null || true)
      if [ -z "$cid" ]; then
        echo "not yet: no summarizer container. Keep the service named 'summarizer' —"
        echo "the grader reads its logs and the volume it mounts."
        exit 1
      fi

      # The uid the app really ran as, from the app itself, rather than from the
      # compose file's idea of it.
      ran_as=$(docker logs "$cid" 2>&1 | sed -n 's/^running as uid \([0-9][0-9]*\).*/\1/p' | tail -1)
      if [ -z "$ran_as" ]; then
        echo "not yet: summarizer never printed its uid line — is it still running summarize.py?"
        docker logs "$cid" 2>&1 | tail -10 | sed 's/^/    /'
        exit 1
      fi
      if [ "$ran_as" = "0" ]; then
        echo "not yet: summarizer ran as uid 0. Putting it back to root makes the"
        echo "error go away and undoes what the security review asked for."
        exit 1
      fi

      # Which non-root uid it is does not matter — the lesson is that the volume
      # and the process have to agree on one. Whatever the app reported is what
      # the volume is then held to.

      vol=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}' "$cid")
      if [ -z "$vol" ]; then
        echo "not yet: summarizer has no named volume at /data. The shared volume is"
        echo "the thing under repair — writing somewhere else avoids the lesson."
        exit 1
      fi

      probe() { docker run --rm -v "$vol:/data" alpine:3.20 "$@"; }

      summary=$(probe cat /data/out/summary.txt 2>/dev/null || true)
      if [ -z "$summary" ]; then
        echo "not yet: the run exited 0 but there is no /data/out/summary.txt on the volume."
        exit 1
      fi

      expected='events: 5
      errors: 2'
      if [ "$summary" != "$expected" ]; then
        echo "not yet: the summary on the volume is not the one summarize.py writes."
        echo "It says:"
        printf '%s\n' "$summary" | sed 's/^/    /'
        echo "Expected:"
        printf '%s\n' "$expected" | sed 's/^/    /'
        exit 1
      fi

      listing=$(probe find /data -exec stat -c '%u %a %n' {} + 2>/dev/null || true)
      if [ -z "$listing" ]; then
        echo "not yet: could not read the volume's contents to check ownership"
        exit 1
      fi

      # chmod -R 777 makes the error go away by making the volume writable by
      # every uid in every container that ever mounts it.
      loose=$(printf '%s\n' "$listing" | awk '$2 ~ /[2367]$/ {print}' || true)
      if [ -n "$loose" ]; then
        echo "not yet: these paths are writable by any user in any container:"
        printf '%s\n' "$loose" | head -5 | sed 's/^/    /'
        echo "World-writable is not ownership. Give the volume to $ran_as instead."
        exit 1
      fi

      wrong=$(printf '%s\n' "$listing" | awk -v u="$ran_as" '$1 != u {print}' || true)
      if [ -n "$wrong" ]; then
        echo "not yet: the app runs as $ran_as, and these paths belong to someone else:"
        printf '%s\n' "$wrong" | head -5 | sed 's/^/    /'
        echo "(uid, mode, path — the exporter runs as root and touches the volume first.)"
        exit 1
      fi

      echo "PASS — summarizer ran as uid $ran_as and the whole volume belongs to it,"
      echo "with no world-writable path anywhere on it."
---
