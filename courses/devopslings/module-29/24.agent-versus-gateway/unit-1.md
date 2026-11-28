---
title: "Agent, gateway, or both"
---

## The situation

The fleet in `/obs/fleet/FLEET.md` is moving from a vendor agent to the
OpenTelemetry Collector. Read it first; every fact in it matters:

- 300 hosts, and one trace's spans come from four to nine of them
- card numbers and emails on some spans, which may not leave the host in
  clear text
- three gateway Collectors behind one load-balanced name
- a vendor backend that goes away for up to ten minutes
- a budget of every error trace and 5% of the rest

The design review wants two Collector configs, one that runs on every host
and one that runs in each gateway, and a sentence on where four jobs live:
tail sampling, redaction, batching and retry.

`otelcol-contrib validate --config <file>` checks a config without starting
it.

## The two tiers

An **agent** runs on every host, next to the applications. It sees only
that host's telemetry, and it is the last thing to touch the data before it
leaves the machine.

A **gateway** is a separate tier that agents send to. It sees what many
hosts send, has its own memory and CPU to spend, and is the one place to
change when the backend changes.

Questions that decide where a job goes:

- **What does the job need to see?** A tail sampler decides on a whole
  trace. If spans of one trace arrive at different Collectors, each one
  decides on a fragment.
- **Where is the trust boundary?** Data removed after it crossed has
  already crossed.
- **What happens on each hop?** Every network hop is an export that can be
  batched and can fail.

One detail decides whether tail sampling works with more than one gateway.
A load balancer spreads *connections*. The `loadbalancing` exporter, used in
the agent, routes each span to a backend chosen by its **trace ID**, so all
spans of a trace reach the same gateway:

```yaml
exporters:
  loadbalancing:
    routing_key: traceID
    protocol:
      otlp: {tls: {insecure: true}}
    resolver:
      static:
        hostnames: [host-a:4317, host-b:4317]
```

Exporters retry by default, with `retry_on_failure` and a `sending_queue`.
The default retry gives up after `max_elapsed_time: 300s`.

## Your objectives

1. `/obs/fleet/agent.yaml`: the per-host Collector.
2. `/obs/fleet/gateway.yaml`: the gateway Collector.
3. `/obs/answers/topology.txt`: for each of tail sampling, redaction,
   batching and retry, `agent`, `gateway` or `both`, then the reason.

## What you're being graded on

- both configs pass `otelcol-contrib validate`
- tail sampling runs in the gateway, and the agents route spans to the
  three gateways by trace ID
- the agents remove or hash `payment.card_number` and `user.email`
- both tiers batch
- the gateway's retry to the vendor lasts through a ten-minute outage
- each line of `topology.txt` names the tier the configs use and gives a
  reason that says why

<details>
<summary>Hint 1 — tail sampling and three gateways</summary>

Send one trace through `gateway.obs.internal` and follow its spans: they
arrive over different agents' connections, and the load balancer put those
connections on different gateways.

</details>

<details>
<summary>Hint 2 — redaction</summary>

The `attributes` processor can `delete` or `hash` a key. Which config does
the card number pass through first?

</details>

<details>
<summary>Solution</summary>

`agent.yaml`: receive on `localhost:4317`; `memory_limiter`, an
`attributes` processor that deletes `payment.card_number` and hashes
`user.email`, `batch`; export with `loadbalancing`, `routing_key: traceID`,
to the three gateway hostnames.

`gateway.yaml`: receive OTLP; `memory_limiter`, `tail_sampling` with a
`status_code` policy for `ERROR` and a 5% `probabilistic` policy, `batch`;
export to `otlp.vendor.example:4317` with `retry_on_failure.max_elapsed_time:
15m` and a `sending_queue` large enough for the outage.

```
tail_sampling: gateway — a sampling decision needs every span of the trace, and only a gateway receiving all of them, routed by trace ID, has the whole trace
redaction: agent — card numbers must not leave the PCI host in clear, so they are removed before the first export, before anything crosses the segment
batching: both — each tier exports over the network, and batching turns per-span requests into a few compressed ones on each hop
retry: both — the agent queues through a gateway restart, the gateway queues through a vendor outage of up to ten minutes
```

The full configs are in the lesson's `solution/solve.sh`.

### The ways this goes wrong

- **Tail sampling in the agent.** Each host sees a slice of every trace; an
  error on host 7 cannot keep the spans host 3 already dropped.
- **Agents to the load balancer's name.** Three gateways each tail-sample a
  third of a trace. It looks fine with one gateway, and breaks the day a
  second one is added.
- **Redaction in the gateway.** Simpler to roll out, and the card numbers
  have already crossed the PCI boundary by then.
- **Default retry towards the vendor.** Five minutes of retries for a
  ten-minute outage: the first half of the outage's data is dropped.
- **Everything in one tier.** Agents only: no whole traces to sample. A
  gateway only: no redaction inside the boundary, and an application whose
  export fails has nowhere local to queue.

</details>
