---
kind: lesson
title: "docker stop takes exactly ten seconds, every time"
description: |
  The app has a clean shutdown handler and it never runs. Every deploy waits
  ten seconds per container and then kills them. Learn what PID 1 is inside a
  container, why the exact number ten is a clue, and what shell-form CMD really
  does.
name: pid1-signals
slug: pid1-signals
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
      import signal, sys, time

      running = True

      def on_term(signum, frame):
          global running
          print("SIGTERM received, draining connections...", flush=True)
          time.sleep(0.2)
          print("graceful shutdown complete", flush=True)
          running = False

      signal.signal(signal.SIGTERM, on_term)

      print("worker started", flush=True)
      while running:
          time.sleep(0.2)
      sys.exit(0)
      PY

      cat > Dockerfile <<'DOCKER'
      FROM python:3.12-slim
      WORKDIR /app
      COPY app.py .
      CMD python3 app.py
      DOCKER

      echo "scenario ready — files are in $(pwd)"
      echo
      echo "Try it:"
      echo "  docker build -t devopslings-pid1 ."
      echo "  docker run -d --name pid1-demo devopslings-pid1"
      echo "  time docker stop pid1-demo"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      img=devopslings-pid1-check
      ctr=devopslings-pid1-check

      cleanup() { docker rm -f "$ctr" >/dev/null 2>&1 || true; }
      trap cleanup EXIT
      cleanup

      if [ ! -f Dockerfile ]; then
        echo "not yet: no Dockerfile in $(pwd)"
        exit 1
      fi

      if ! docker build -q -t "$img" . >/dev/null 2>&1; then
        echo "not yet: the image does not build — run 'docker build -t $img .' to see why"
        exit 1
      fi

      docker run -d --name "$ctr" "$img" >/dev/null
      # Let the app install its signal handler before we signal it.
      sleep 2

      # The measurement that matters. A container whose PID 1 ignores SIGTERM
      # sits out the full grace period and is then killed; one that handles it
      # exits promptly.
      start=$(date +%s)
      docker stop "$ctr" >/dev/null 2>&1 || true
      elapsed=$(( $(date +%s) - start ))

      logs=$(docker logs "$ctr" 2>&1 || true)

      if [ "$elapsed" -ge 5 ]; then
        echo "not yet: docker stop took ${elapsed}s — PID 1 is still ignoring SIGTERM"
        exit 1
      fi

      # Fast exit alone is not proof. A container could stop quickly because the
      # process died, rather than because it shut down deliberately.
      if ! printf '%s' "$logs" | grep -q 'graceful shutdown complete'; then
        echo "not yet: it stopped in ${elapsed}s but never logged 'graceful shutdown complete' — the handler still isn't running"
        exit 1
      fi

      # The app must still be the thing running; wrapping it in a supervisor
      # that exits on its own would pass the timing check for the wrong reason.
      if ! printf '%s' "$logs" | grep -q 'worker started'; then
        echo "not yet: the app never logged 'worker started' — is it still the container's main process?"
        exit 1
      fi

      echo "PASS — stopped in ${elapsed}s and drained cleanly. SIGTERM reached the app."
---
