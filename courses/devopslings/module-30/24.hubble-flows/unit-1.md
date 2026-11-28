---
title: "the network policy looks right, and the flow is dropped"
---

## The situation

`orders` in namespace `shop` cannot reach `orders-db` on 5432. Connections time
out; nothing is refused. The NetworkPolicy on `orders-db` allows ingress from
pods labelled `app: orders`, and the `orders` pods carry that label. Everyone
who has read the policy agrees it is right.

The first guess is to open it up — allow the whole namespace, or delete the
policy — and see if that helps. It does, and it removes the isolation the
policy was written for.

On a cluster whose network plugin is [Cilium](https://cilium.io), Hubble records
every flow the datapath forwarded or dropped, with the verdict and, for a drop,
the reason:

```
$ hubble observe --namespace shop --verdict DROPPED
shop/orders-7c9f... -> shop/orders-db-0:5432 policy-verdict:none INGRESS DENIED (TCP Flags: SYN)
```

That line names the source and destination identity the policy was evaluated
against. The policy matches labels; the drop says which labels the source was
actually seen with.

## What the lesson will grade

- the dropped flow is named from Hubble, with its policy verdict
- the policy fix lets that flow through without allowing the whole namespace,
  and a pod without the right labels is still dropped

## Why this lesson cannot run yet

Hubble is part of Cilium, and Cilium is a Kubernetes network plugin: it needs a
cluster whose pods it networks. Every sandbox in this course is a Docker Compose
stack, and none runs Kubernetes. A Hubble lesson without Cilium would be a
transcript to read, not a flow to find.

Kubernetes networking belongs in
[kubelings](https://github.com/madhank93/kubelings) (see module 28's handoffs).
This lesson is unblocked by a sandbox here that runs a Cilium cluster (kind or
k3d with Cilium installed), or by moving it there.

Without Kubernetes, the same question — which rule dropped this packet — is
answered on a plain host by nftables tracing in module 04's `trace-the-drop`.
