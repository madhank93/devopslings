---
title: "The customer's failed checkout is in no trace"
---

## The situation

checkout places about 25 orders a second and records each with ledger.
Storing a trace for every order blew the tracing bill, so checkout keeps one
in a hundred: `ParentBased(TraceIdRatioBased(0.01))`, and ledger follows.

This morning a customer's order failed with a 500. Support has the order id
and the time, and there is no trace for it. There is no trace for most
failed orders:

```
curl -s 'http://tempo:3200/api/search?q={status=error}&limit=50' | jq '.traces | length'
```

About 1% of orders fail, and 1% of those are kept: a few an hour. The slow
ones, which the on-call most needs to look at, fare no better.

The source is `/obs/apps/checkout.py`; the Collector's config is
`/obs/otel/collector.yaml`, and its output is in `/obs/logs/collector.log`.
Saving either restarts it.

## Head and tail

**Head sampling** decides when the root span starts: before the request has
run, with nothing to go on but the trace id. It is cheap — a dropped trace
is never recorded, exported or stored — and it is blind. A 1% head sampler
keeps 1% of errors and 1% of slow requests, exactly because it cannot tell
them apart from the rest.

**Tail sampling** decides after the trace is complete. Every span is sent
to the Collector, which holds the spans of each trace for `decision_wait`
and then applies policies to the whole trace: keep it if any span has
status `ERROR`; keep it if it lasted longer than a threshold; keep a
fraction of whatever is left. The Collector contrib distribution has it as
the `tail_sampling` processor:

```yaml
processors:
  tail_sampling:
    decision_wait: 10s
    policies:
      - name: <any name>
        type: status_code            # or latency, probabilistic, string_attribute, ...
        status_code: {status_codes: [ERROR]}
```

A trace is kept when any policy says keep. The price is moving the cost:
apps now export everything, and the Collector holds every trace in memory
for `decision_wait`. It also needs every span of a trace to reach the same
Collector — which holds here, with one Collector; the next lesson,
`tail-sampling-needs-the-whole-trace`, is what happens when it does not.

## Your objectives

Keep every trace with an error and every trace over 500 ms, and about 1% of
the rest, so the stored volume stays under 5% of orders.

## What you're being graded on

While checkout's customers keep ordering, the check places 8 orders that
fail and 5 that take 600 ms. For half of them the body says so (`"card":
"declined"`, `"slow": true`); for the rest ledger fails or stalls, which
nothing knows when the request starts. Then:

- all 13 are in Tempo (the check waits up to 90 s for the sampling decision)
- the checkout traces stored while it ran are at most 5% of the customers'
  orders, and at least one is an ordinary order: neither an error nor slow

<details>
<summary>Hint 1 — why 100% alone is not it</summary>

Every error is findable at 100%, and the stored volume is a hundred times
the budget. The check counts stored traces against orders placed.

</details>

<details>
<summary>Hint 2 — two changes</summary>

The Collector can only keep what reaches it. checkout's head sampler has to
let every trace through, and the Collector's traces pipeline gets a
processor with three policies. `tail_sampling` goes before `batch`.

</details>

<details>
<summary>Solution</summary>

In `/obs/apps/checkout.py`, send every trace (`TraceIdRatioBased(1.0)`, or
drop the `sampler=` argument for the default, `ParentBased(ALWAYS_ON)`).

In `/obs/otel/collector.yaml`:

```yaml
processors:
  batch:
    timeout: 1s
  tail_sampling:
    decision_wait: 5s
    policies:
      - name: errors
        type: status_code
        status_code: {status_codes: [ERROR]}
      - name: slow
        type: latency
        latency: {threshold_ms: 500}
      - name: baseline
        type: probabilistic
        probabilistic: {sampling_percentage: 1}

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [tail_sampling, batch]
      exporters: [otlphttp/tempo]
```

`decision_wait` has to outlast your slowest trace; 30 s is the default and
safe, 5 s is enough here and keeps less in memory. The 1% baseline is not
decoration: without ordinary traces you cannot compare a slow trace with a
normal one, and spanmetrics computed after this processor would describe
only failures.

### The ways this goes wrong

- **Sampling 100% everywhere.** Every error is there, and so is everything
  else, at 100× the budget.
- **Tail sampling with checkout still at 1%.** The Collector keeps every
  error it receives, and it receives 1% of them.
- **Only an error policy.** The 600 ms orders succeed and are dropped.
- **No probabilistic policy.** Under budget, and nothing ordinary left to
  compare against.
- **`tail_sampling` after `batch`.** It works, but batching first wastes
  work on spans about to be dropped; the processor's docs put it first.

</details>
