---
kind: lesson
title: "Hold the line: the SLO through a release and a failure"
description: |
  checkout has an SLO: 99.9% of requests answered, p99 within 500ms. It has
  to hold while a release goes out and while a replica is taken away, under
  load that does not slow down for either. As shipped, a release replaces
  both replicas at once. Make releases and shutdowns invisible to customers.
name: stage-3-hold-the-line
slug: stage-3-hold-the-line
createdAt: "2026-11-18"
timingSensitive: true

sandbox:
  stack: ha-stack
  with: [ci-stack, obs-stack]
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 1200
    run: |
      bash "$DEVOPSLINGS_ROOT/courses/devopslings/module-27/03.stage-3-hold-the-line/files/init.sh"

  inject_fault:
    timeout_seconds: 120
    run: |
      bash "$DEVOPSLINGS_ROOT/courses/devopslings/module-27/03.stage-3-hold-the-line/files/inject.sh"

  verify_done:
    needs: [init_scenario, inject_fault]
    timeout_seconds: 1500
    run: |
      bash "$DEVOPSLINGS_ROOT/courses/devopslings/module-27/03.stage-3-hold-the-line/files/verify.sh"
---
