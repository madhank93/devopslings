---
kind: lesson
title: "RED metrics for a service nobody will instrument"
description: |
  A legacy service has no tracing SDK and nobody willing to add one. Beyla
  attaches eBPF programs to the running process and produces RED metrics and
  server spans from the kernel, with no code change. Not runnable yet: Beyla's
  programs do not load on arm64, and a lesson here has to run on both arm64
  and x86_64.
name: ebpf-auto-instrumentation
slug: ebpf-auto-instrumentation
createdAt: "2026-11-23"

sandbox:
  stack: obs-stack
  service: box

# Beyla 2.5's uprobe programs fail the arm64 verifier. Unmet everywhere until a
# Beyla release loads on arm64; the lesson has no tasks until then.
requires: [beyla-arm64]
---
