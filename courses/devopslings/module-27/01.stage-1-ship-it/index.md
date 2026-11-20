---
kind: lesson
title: "Ship it: one commit, all the way to the VIP"
description: |
  A commit to checkout has to reach production on its own: built once by CI,
  pushed to the registry by digest, applied by OpenTofu from shared state,
  and served by two replicas behind the HA pair. Nothing here is new; every
  link is a check from an earlier module, and none of them may be skipped.
name: stage-1-ship-it
slug: stage-1-ship-it
createdAt: "2026-11-17"

sandbox:
  stack: ha-stack
  with: [ci-stack]
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 600
    run: |
      bash "$DEVOPSLINGS_ROOT/courses/devopslings/module-27/files/seed.sh"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 1200
    run: |
      bash "$DEVOPSLINGS_ROOT/courses/devopslings/module-27/files/stage-1-verify.sh"
---
