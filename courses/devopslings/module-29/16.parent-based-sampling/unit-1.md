---
title: "Tempo is full of ledger spans with no order above them"
---

## The situation

checkout takes an order every 150ms or so and records each one with ledger
over HTTP. Tracing every order costs more than the team will pay, so checkout
traces one in five. ledger's team had the same bill and made their own cut:
ledger traces half of its requests.

Since then Tempo has filled with traces that start at ledger:

```
curl -s 'http://tempo:3200/api/search?q={resource.service.name="ledger"}&limit=10' | jq '.traces[].rootServiceName'
```

Many say `<root span not yet received>`. The root is never coming. The
on-call cannot tell these from a real lost span, and searches for ledger
latency count requests whose order nobody traced.

Both services' source is in `/obs/apps/` (`checkout.py`, `ledger.py`). Saving
a file restarts that service, and its output is in `/obs/logs/<name>.log`.

## Who decides

A **sampler** runs when a span starts and decides whether it is recorded
and exported. The decision travels with the trace context, in the last field
of the `traceparent` header:

```
traceparent: 00-<trace id>-<parent span id>-01    # 01: sampled, 00: not
```

`TraceIdRatioBased(0.5)` decides from the trace ID alone: it keeps a trace
when the low 64 bits of its ID fall in the bottom half of the range. It
never looks at the flag. Two services with different ratios therefore make
different decisions about the same trace, and whichever service keeps a span
the other dropped leaves a fragment.

`ParentBased(root_sampler)` looks at the parent first. When the incoming
context says sampled, it records; when it says not sampled, it does not;
only a span with no parent at all goes to `root_sampler`. So the service
where a request enters makes the decision once, and everything downstream
follows it. That is **head sampling** done consistently. checkout already
uses it, which is why checkout's own spans are never orphans.

The spec lets the sampler also be set from the environment
(`OTEL_TRACES_SAMPLER=parentbased_traceidratio`), but a sampler passed to
`TracerProvider` in code wins over it.

## Your objectives

Make every trace in Tempo whole: each order checkout traces has ledger's
span in it, and no ledger span is stored for an order checkout did not
trace. Keep checkout at one order in five.

## What you're being graded on

On the orders taken after your last edit:

- every trace with a ledger span in it has checkout's `POST /checkout` as
  its root, and every checkout trace has a ledger span
- ledger follows the sampled flag of the request it receives: the check
  sends ledger one request marked sampled whose trace ID ledger's own ratio
  would drop, and one marked not sampled that its ratio would keep

<details>
<summary>Hint 1 — why the ratio is not the knob</summary>

Try ledger at 1.0 and at 0.1, and count orphans and orders with no ledger
span each time. Raising it makes more orphans, lowering it drops ledger out
of traces checkout kept. Setting it to exactly checkout's ratio happens to
line up, but only because both use the same arithmetic on the same IDs;
the check's two requests show it is still ledger deciding.

</details>

<details>
<summary>Hint 2 — the sampler that asks the parent</summary>

`opentelemetry.sdk.trace.sampling` has a sampler that wraps another one
and consults it only when there is no parent. checkout's `TracerProvider`
uses it.

</details>

<details>
<summary>Solution</summary>

In `/obs/apps/ledger.py`:

```python
from opentelemetry.sdk.trace.sampling import ParentBased, TraceIdRatioBased

provider = TracerProvider(resource=Resource.create({"service.name": "ledger"}),
                          sampler=ParentBased(TraceIdRatioBased(0.5)))
```

Every request ledger serves today comes from checkout with a context, so
the 0.5 now only matters for a request that arrives with no trace at all,
such as a health check or a batch job calling ledger directly.

### The ways this goes wrong

- **Raising ledger's ratio.** At 1.0 ledger keeps every request, including
  the four in five whose order is not traced: more orphans, not fewer.
- **Lowering it.** At 0.1 ledger drops spans from orders checkout kept, and
  those traces end at checkout's client span with nothing beneath it.
- **Matching checkout's ratio.** Both at 0.2 agree today, because the
  Python SDK's ratio sampler compares the same 64 bits against the same
  bound. Another SDK, another language or a different ratio upstream breaks
  it again, and the check's probe requests catch it.
- **Deleting ledger's sampler.** The default is `ParentBased(ALWAYS_ON)`,
  which passes. It also means a request with no parent is always traced,
  which is a choice to make on purpose rather than by deletion.
- **Filtering orphans in the Collector.** A processor that drops spans whose
  root is missing cannot know the root is not just late, and it does nothing
  for the traces that lost their ledger span.

</details>
