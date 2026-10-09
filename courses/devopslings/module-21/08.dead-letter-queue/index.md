---
kind: lesson
title: "One poison message stops the queue"
description: |
  An order consumer retries anything that fails, because the stock service it
  calls is sometimes briefly busy. Then a malformed order arrives. It fails
  every time, the consumer retries it forever, and every order behind it waits.
  Bound the retries and park the message — without losing anything.
name: dead-letter-queue
slug: dead-letter-queue
createdAt: "2026-10-08"

sandbox:
  stack: chaos-stack
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-21/*.dead-letter-queue
      lesson=$1
      work="$DEVOPSLINGS_ROOT/scratch/dead-letter-queue"

      # The consumer lives outside the repo and outside any container, so a
      # reset has to put the starting version back here.
      mkdir -p "$work"
      cp "$lesson/files/consumer.py" "$lesson/files/orders.py" "$lesson/files/run.sh" "$work/"
      chmod +x "$work/run.sh"

      echo "scenario ready — the queue is healthy and drains."
      echo
      bash "$work/run.sh" | tail -n 5
      echo
      echo "Your files: $work"
      echo "At verify time the queue is refilled with order 4 malformed. The good"
      echo "orders must all ship, and order 4 must end up in dead_letter. See the task."

  # The fault is the message, not the network. Everything here is the lesson's
  # own: its orders.py, a fresh queue, and no student file is read. Seeding
  # also stops any consumer left running from the student's own runs.
  inject_fault:
    timeout_seconds: 60
    run: |
      set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-21/*.dead-letter-queue
      ctr=devopslings-chaos-stack-checkout-1
      docker exec "$ctr" mkdir -p /srv/queue
      docker cp -q "$1/files/orders.py" "$ctr:/srv/queue/orders.py"
      docker exec -w /srv/queue "$ctr" python3 orders.py seed --poison
      echo "fault injected: order 4 of 30 is malformed"

  verify_done:
    needs: [init_scenario, inject_fault]
    timeout_seconds: 180
    run: |
      set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-21/*.dead-letter-queue
      lesson=$1
      work="$DEVOPSLINGS_ROOT/scratch/dead-letter-queue"
      ctr=devopslings-chaos-stack-checkout-1

      if [ ! -f "$work/consumer.py" ]; then
        echo "not yet: $work/consumer.py is missing. Reset the lesson to get the starting version back."
        exit 1
      fi

      docker cp -q "$work/consumer.py" "$ctr:/srv/queue/consumer.py"
      docker cp -q "$lesson/files/grade.py" "$ctr:/srv/queue/grade.py"

      # 30s is several times what a bounded consumer needs; a consumer still
      # running then is retrying something that will not succeed.
      rc=0
      out=$(docker exec -w /srv/queue "$ctr" timeout 30 python3 consumer.py 2>&1) || rc=$?
      if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
        echo "consumer.py exited with status $rc. Last lines of its output:"
        printf '%s\n' "$out" | tail -n 8
        echo
      fi

      docker exec -w /srv/queue "$ctr" python3 grade.py "$rc"
---
