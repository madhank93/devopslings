---
kind: lesson
title: "At-least-once delivery charges twice"
description: |
  A client retries a payment when no answer comes back — which is the right
  thing to do, because the network does lose answers. But some of those
  answers were lost after the charge was recorded, and the retry charges the
  customer again. Make the retry safe to repeat.
name: idempotency-keys
slug: idempotency-keys
createdAt: "2026-10-08"

sandbox:
  stack: chaos-stack
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-21/*.idempotency-keys
      lesson=$1
      work="$DEVOPSLINGS_ROOT/scratch/idempotency-keys"

      # The student's two files live outside the repo and outside any
      # container, so a reset has to put the starting versions back here.
      mkdir -p "$work"
      cp "$lesson/files/payments.py" "$lesson/files/client.py" "$lesson/files/run.sh" "$work/"
      chmod +x "$work/run.sh"

      curl -fsS -X DELETE http://127.0.0.1:8474/proxies/payments/toxics/lost_response \
        >/dev/null 2>&1 || true

      echo "scenario ready — payments is healthy, and so is the network to it."
      echo
      bash "$work/run.sh" | tail -n 4
      echo
      echo "Your files: $work"
      echo "At verify time, 1 in 4 responses from payments will be lost on the way"
      echo "back — after the charge is recorded. Every order must be charged exactly"
      echo "once, and every customer told it worked. See the task."

  # Grader-owned only: the proxy is toxiproxy runtime state, so it is recreated
  # here if a toxiproxy restart lost it, and nothing the student edits is read.
  inject_fault:
    timeout_seconds: 60
    run: |
      if ! curl -fsS http://127.0.0.1:8474/proxies/payments >/dev/null 2>&1; then
        curl -fsS -X POST http://127.0.0.1:8474/proxies -H 'Content-Type: application/json' \
          -d '{"name":"payments","listen":"0.0.0.0:21081","upstream":"pricing:8081","enabled":true}' \
          >/dev/null
      fi
      curl -fsS -X DELETE http://127.0.0.1:8474/proxies/payments/toxics/lost_response \
        >/dev/null 2>&1 || true

      # limit_data at 0 bytes closes the connection as the first byte of the
      # response arrives: the request reached payments and was committed, and
      # the client sees only a dropped connection.
      curl -fsS -X POST http://127.0.0.1:8474/proxies/payments/toxics \
        -H 'Content-Type: application/json' \
        -d '{"name":"lost_response","type":"limit_data","stream":"downstream","toxicity":0.25,"attributes":{"bytes":0}}' \
        >/dev/null

      echo "fault injected: 1 in 4 responses from payments lost after the charge"

  verify_done:
    needs: [init_scenario, inject_fault]
    timeout_seconds: 300
    run: |
      set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-21/*.idempotency-keys
      lesson=$1
      work="$DEVOPSLINGS_ROOT/scratch/idempotency-keys"
      pay=devopslings-chaos-stack-pricing-1

      for f in payments.py client.py; do
        if [ ! -f "$work/$f" ]; then
          echo "not yet: $work/$f is missing. Reset the lesson to get the starting version back."
          exit 1
        fi
      done

      # The lesson's run.sh, not the student's copy: it deploys their two files
      # and empties the ledger first, so every grade starts from zero charges.
      rc=0
      out=$(bash "$lesson/files/run.sh" "$work" 2>&1) || rc=$?
      if [ "$rc" -eq 3 ]; then
        echo "not yet: payments.py did not start, so no order could be charged."
        printf '%s\n' "$out" | tail -n 16
        exit 1
      elif [ "$rc" -ne 0 ]; then
        echo "not yet: the batch could not be run — this looks like the sandbox rather than"
        echo "your code. Reset the scenario and retry. Output:"
        printf '%s\n' "$out" | tail -n 10
        exit 1
      fi

      docker cp -q "$lesson/files/grade.py" "$pay:/srv/payments/grade.py"
      if printf '%s\n' "$out" | docker exec -i "$pay" python3 /srv/payments/grade.py; then
        curl -fsS -X DELETE http://127.0.0.1:8474/proxies/payments/toxics/lost_response \
          >/dev/null 2>&1 || true
        exit 0
      fi
      # On failure the fault stays on, so run.sh reproduces what was graded.
      exit 1
---
