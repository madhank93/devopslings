#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The exporter is a vendor image and stays root, so the volume it seeds is
# root-owned. A one-shot service between it and the app hands the volume to the
# uid the app actually runs as — the compose spelling of an init container.
set -euo pipefail

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

  fixperms:
    image: alpine:3.20
    command: ["chown", "-R", "10001:10001", "/data"]
    depends_on:
      exporter:
        condition: service_completed_successfully
    volumes:
      - reports:/data

  summarizer:
    build: .
    depends_on:
      fixperms:
        condition: service_completed_successfully
    volumes:
      - reports:/data

volumes:
  reports:
YAML
