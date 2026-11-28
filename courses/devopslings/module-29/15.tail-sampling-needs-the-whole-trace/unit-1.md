---
title: "Every error trace in Tempo has lost its root"
---

## The situation

checkout takes an order every 300ms or so and records it with ledger. About
one ledger write in twelve fails with a lock timeout. checkout copes (a
retry job picks the entry up later), so checkout's own span stays OK; the
error is on ledger's span.

The two services sit in different zones, and each zone has its own gateway
Collector: checkout sends to `collector`, ledger to `collector-2`. Both
gateways run the same tail-sampling policy: keep every trace with an error,
and one in ten of the rest. Their configs are `/obs/otel/collector.yaml` and
`/obs/otel/collector-2.yaml`; each restarts on save and logs to
`/obs/logs/<name>.log`.

Every error trace in Tempo looks like this:

```
curl -s -G http://tempo:3200/api/search --data-urlencode 'q={status=error}' | jq '.traces[].rootServiceName'
"<root span not yet received>"
```

The team's first move was to raise `decision_wait` from 5s to 60s, on the
theory that checkout's spans arrive late.

## Why tail sampling needs the whole trace

A tail sampler buffers spans by trace ID for `decision_wait`, then applies
its policies to everything it has for that trace. It can only decide on what
it was sent. Here `collector-2` sees ledger's span with the error and keeps
it; `collector` sees checkout's spans, no error, and keeps one trace in ten.
Waiting longer changes nothing: checkout's half is never going to arrive at
`collector-2`.

The usual fix is a routing layer in front of the samplers: the
`loadbalancing` exporter hashes each span's **trace ID** to pick one backend,
so every span of a trace lands on the same sampler, whichever Collector
received it first:

```yaml
exporters:
  loadbalancing:
    routing_key: traceID
    protocol:
      otlp:
        tls: {insecure: true}
    resolver:
      static:
        hostnames: [host-a:4417, host-b:4417]
```

The routing layer and the sampling layer can be separate Collectors, or two
pipelines in the same one, each with its own receiver.

## Your objectives

Make every trace Tempo stores whole, keeping the policy: every error trace,
one in ten of the rest. The services keep sending where they send today.

## What you're being graded on

On orders taken after your last edit:

- every trace with a failed ledger write has checkout's root span in it,
  and every checkout trace has its ledger span
- Tempo stores roughly the policy's share, not everything
- both gateways route spans with a `loadbalancing` exporter, by trace ID

<details>
<summary>Hint 1 — the decision_wait theory</summary>

Raise it to 60s and look at the error traces a minute later. Then look at
which gateway received checkout's spans for one of them.

</details>

<details>
<summary>Hint 2 — two pipelines</summary>

In each gateway: one pipeline receives from the services and exports with
`loadbalancing` to both gateways on a second port; a second pipeline
receives on that port, tail-samples, and exports to Tempo.

</details>

<details>
<summary>Solution</summary>

In both `/obs/otel/collector.yaml` and `/obs/otel/collector-2.yaml`, add a
receiver and an exporter, and split the pipeline:

```yaml
receivers:
  # ...otlp as before, plus:
  otlp/sampling:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4417

exporters:
  # ...otlphttp/tempo as before, plus:
  loadbalancing:
    routing_key: traceID
    protocol:
      otlp:
        tls:
          insecure: true
    resolver:
      static:
        hostnames: [collector:4417, collector-2:4417]

service:
  pipelines:
    traces/route:
      receivers: [otlp]
      exporters: [loadbalancing]
    traces:
      receivers: [otlp/sampling]
      processors: [tail_sampling, batch]
      exporters: [otlphttp/tempo]
```

Both gateways list the same backends in the same order, so they agree on
which one owns a trace.

### The ways this goes wrong

- **Raising `decision_wait`.** More memory, later decisions, the same
  fragments.
- **Turning sampling off, or on only in one gateway.** Traces come out
  whole and storage goes up tenfold, or one half of every trace is always
  kept and the other is not.
- **Pointing both services at one gateway.** Whole traces today, and the
  same split the day a second gateway is added behind a load balancer.
- **Routing by service.** Every checkout span on one gateway and every
  ledger span on the other: exactly the problem you started with.

</details>
