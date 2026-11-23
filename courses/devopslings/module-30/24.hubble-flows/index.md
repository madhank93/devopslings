---
kind: lesson
title: "the network policy looks right, and the flow is dropped"
description: |
  A pod's requests to its database time out, and the NetworkPolicy reads as
  if it allows them. Hubble, Cilium's flow observer, shows the dropped flow
  and the policy verdict that dropped it. Not runnable here: it needs Kubernetes
  with Cilium as the network plugin, which no sandbox in this course provides.
name: hubble-flows
slug: hubble-flows
createdAt: "2026-11-23"

sandbox:
  stack: none
  service: host

# Needs a Kubernetes cluster running Cilium. Kubernetes lessons live in
# kubelings; this stays a pointer until a sandbox here provides one.
requires: [cilium-kubernetes]
---
