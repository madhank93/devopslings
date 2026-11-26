---
title: "RED metrics for a service nobody will instrument"
---

## The situation

`ledger-legacy` has served the same HTTP API for six years. It has no
OpenTelemetry SDK, its build is not reproducible, and the team that owned it is
gone. Every other service on the dashboard has request rate, error rate and
duration; this one is a gap in every trace that crosses it.

The first guess is to add the SDK. That is a code change, a rebuild and a
redeploy of the one service nobody can rebuild with confidence.

[Grafana Beyla](https://grafana.com/docs/beyla/latest/) instruments from
outside the process: it attaches eBPF uprobes and kprobes to the running binary
and the kernel's socket paths, reconstructs each HTTP request from them, and
exports RED metrics and server spans over OTLP. The service is not touched.

## What the lesson will grade

- RED metrics and server spans for `ledger-legacy` appear in `obs-stack`
  (Prometheus and Tempo) with no change to the service's code or image
- the request count Beyla reports matches the count the grader drives

## Why this lesson cannot run yet

Beyla 2.5 does not load on aarch64. Its uprobe programs are rejected by the
kernel's eBPF verifier there, and it cannot parse the Go symbol sections it
needs to find functions in Go binaries. The sandbox shares the Docker host's
kernel, so a Mac (arm64) cannot run it at all.

CI runners are x86_64, where Beyla loads, but a lesson in this course has to
pass on the machines students actually use as well as on CI. A grader that only
works on one architecture would fail half the people taking it for reasons that
have nothing to do with their work.

It is unblocked by either of:

- a Beyla release whose programs pass the arm64 verifier — re-probe on an
  arm64 Docker host before building the lesson
- a decision that this lesson is x86_64-only, with a `requires:` check the
  runner can actually evaluate

Until then, `ebpf-in-production` in this module uses the same verifier failure
as evidence: an eBPF agent that works on one kernel and architecture is not
proven to work on the next.
