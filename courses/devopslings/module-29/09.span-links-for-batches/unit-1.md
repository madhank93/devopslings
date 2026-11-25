---
title: "Forty-nine orders a batch never reach fulfilment"
---

## The situation

checkout takes about ten orders a second and publishes each one to `broker`,
an in-memory queue, with the trace context in the message's headers. fulfil
wakes every two seconds, takes up to fifty orders, and books them with the
warehouse in a single call: one unit of work, one span.

Support asked why order `ord-…` shipped late, opened its trace, and found it
ends at `orders publish`. Count how many orders have a fulfil span at all:

```
curl -s 'http://tempo:3200/api/search?q={resource.service.name="fulfil"}&limit=50' | jq '.traces | length'
curl -s 'http://tempo:3200/api/search?q={name="POST /checkout"}&limit=50' | jq '.traces | length'
```

One in fifty, near enough. The source is `/obs/apps/fulfil.py` (with
`checkout.py`, `broker.py` and the shared `otel_setup.py` beside it). Saving a
file restarts that service; output is in `/obs/logs/<name>.log`.

## One parent, many links

A span has exactly one parent. That is what makes a trace a tree, and it is
the right model for a request that causes the next request. A batch is not
that shape: fifty producers each caused part of one piece of work.
fulfil handles that by taking `batch[0]`'s context as the parent, and the
other forty-nine orders' traces never learn their order was shipped.

The OpenTelemetry specification gives spans **links** for exactly this. A
link is a reference to another span context — trace id and span id — attached
when the span starts:

```python
trace.Link(span_context, attributes={...})
tracer.start_as_current_span("...", links=[...])
```

A link adds no edge to the tree; it says "this span is related to that one".
The messaging semantic conventions use it for batch consumers: the batch span
links to the creation context of every message it processes. Tempo shows a
span's links in the span details, and each one opens the linked trace.

To turn a message's headers into a span context: `propagate.extract(headers)`
returns a `Context`; `trace.get_current_span(ctx).get_span_context()` takes
the span context out of it.

## Your objectives

Make every order's trace reachable from the fulfil span that processed its
batch. Keep fulfil processing in batches, one span per batch.

## What you're being graded on

The check places 60 orders of its own, each with a trace id it chose, and
waits for fulfil to process them. Then:

- every one of those traces is linked from a fulfil `CONSUMER` span, or is
  the parent trace of a batch span that links the rest of its batch
- a sample of the links point at the `orders publish` span in the order's
  trace — the context checkout put in the message

<details>
<summary>Hint 1 — why picking a different parent does not help</summary>

Whichever order you choose as the parent, the other forty-nine are left
out. A span per order, each parented to its message, gives every trace a
fulfil span but turns one booking call into fifty spans that each claim to
have done it.

</details>

<details>
<summary>Hint 2 — where the links come from</summary>

Every message in `batch` has `headers`. Build one `trace.Link` per message
before starting the span, and pass the list as `links=`. Whether the batch
span keeps a parent is up to you; with links to all fifty, a parent adds
nothing.

</details>

<details>
<summary>Solution</summary>

In `/obs/apps/fulfil.py`:

```python
def process(batch):
    links = [trace.Link(trace.get_current_span(propagate.extract(m["headers"])).get_span_context())
             for m in batch]
    with tracer.start_as_current_span("orders process", links=links,
                                      kind=trace.SpanKind.CONSUMER) as span:
        ...
```

The batch span now starts a trace of its own, and each of its fifty links
opens an order's trace. In Tempo's trace view, the batch span lists them
under "Links".

Links are set at start, so collect them before the span begins; the SDK
caps a span at 128 links by default (`OTEL_SPAN_LINK_COUNT_LIMIT`), enough
for a batch of fifty and a number to know when batches grow.

### The ways this goes wrong

- **The first message as parent** — the starting code: 1 of 50 reachable.
- **The last, or a random one** — the same count.
- **Linking only the messages that are not the parent** — that works too:
  the parent's trace is reachable through the parent.
- **One span per message** — every trace gets a fulfil span, but the batch
  is no longer one unit: its duration, errors and the one booking call are
  repeated fifty times. The check rejects it.
- **A link built from a fresh span instead of the message** — the trace id
  is new, and the order is still unreachable.

</details>
