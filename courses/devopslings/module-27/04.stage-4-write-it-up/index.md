---
kind: lesson
title: "Write it up: the postmortem and the runbook"
description: |
  Stage 2's fault is fixed and stage 3's experiment is over. Write the
  postmortem from what was recorded, not from memory, and the runbook the
  next on-call will follow: every command in it is run against production,
  which has to still be serving when the runbook is done.
name: stage-4-write-it-up
slug: stage-4-write-it-up
createdAt: "2026-11-17"

sandbox:
  stack: ha-stack
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      bash "$DEVOPSLINGS_ROOT/courses/devopslings/module-27/04.stage-4-write-it-up/files/init.sh"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 600
    run: |
      bash "$DEVOPSLINGS_ROOT/courses/devopslings/module-27/04.stage-4-write-it-up/files/verify.sh"
---
