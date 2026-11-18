---
kind: lesson
title: "Break it: a fault nobody names"
description: |
  checkout is in production, shipped by the pipeline from stage 1, and
  something has gone wrong with it. One fault was drawn from five and put
  somewhere in the path from commit to www: the code, the build, the
  pipeline, the registry or the state. The notes say what was seen, not where.
  Fix the cause, so that the next commit nobody touches still ships.
name: stage-2-break-it
slug: stage-2-break-it
createdAt: "2026-11-17"

sandbox:
  stack: ha-stack
  with: [ci-stack]
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 1200
    run: |
      bash "$DEVOPSLINGS_ROOT/courses/devopslings/module-27/02.stage-2-break-it/files/init.sh"

  # Puts the environment the fault is replayed in back to its start before
  # every check; nothing the student owns is touched.
  inject_fault:
    timeout_seconds: 120
    run: |
      bash "$DEVOPSLINGS_ROOT/courses/devopslings/module-27/02.stage-2-break-it/files/inject.sh"

  verify_done:
    needs: [init_scenario, inject_fault]
    timeout_seconds: 1500
    run: |
      bash "$DEVOPSLINGS_ROOT/courses/devopslings/module-27/02.stage-2-break-it/files/verify.sh"
---
