---
title: "Every order's trace stops at the queue"
---

## The situation

An order goes through four services. checkout takes it and publishes it to
broker, an in-memory queue. fulfil takes it off the queue and records it with
ledger over HTTP. checkout, fulfil and ledger all use the OpenTelemetry SDK
and send their spans to Tempo.

Open one order in Grafana (Explore, then the Tempo datasource) and it is two
traces. checkout's trace ends at `publish orders`. fulfil's trace starts at
`process orders`, with no parent, and carries on into ledger. Nothing links
the two except the order ID. The team's first guess is that fulfil's tracer is
misconfigured.

The services' source is in `/obs/apps/`. Saving a file restarts that service,
and its output is in `/obs/logs/<name>.log`.

## How a trace crosses a process

A trace is a tree of spans that share a trace ID. Each span records its
parent's span ID. Inside one process, the SDK keeps the current span in a
**context**, and a new span takes the current one as its parent.

Between processes there is no shared memory, so the context has to travel
with the request. **Propagation** does that. The sender **injects** the
current context into a carrier, which is any string-to-string map, and the
receiver **extracts** it and starts its span with it as the parent. The W3C
format is one value:

```
traceparent: 00-<32 hex trace id>-<16 hex parent span id>-01
```

fulfil already does this on its call to ledger, in `record()` in
`/obs/apps/fulfil.py`, and ledger extracts it in `do_POST`:

```python
headers = {"Content-Type": "application/json"}
propagate.inject(headers)                      # fulfil, while its span is current
...
ctx = propagate.extract(self.headers)          # ledger
with tracer.start_as_current_span("POST /entries", context=ctx, kind=...):
```

Over HTTP the carrier is the request headers. A queue needs a carrier that
travels with the **message**. Kafka, RabbitMQ and SQS all have message
headers or attributes for this. broker is simpler: it queues the body of
what you publish and nothing else. Look at what it holds:

```
curl -s http://broker:8080/peek | jq
```

A **span link** is something else. It records that a span is related to a
span in another trace, for example one consumer span that processes a batch
of messages from many traces. It does not make the two one trace.

## Your objectives

Make each order one trace: checkout's spans, then fulfil's `process orders`
as a child of checkout's span, then ledger's `POST /entries` under that.

## What you're being graded on

The check looks at orders taken after your last edit, as Tempo has them:

- each trace that has fulfil's `process orders` span in it also has checkout's
  spans and ledger's
- the consumer span is a child, not a separate trace with a link

<details>
<summary>Hint 1 — where the context stops</summary>

Look at the messages on broker with `/peek`. Is there anything in them that
fulfil could continue a trace from?

</details>

<details>
<summary>Hint 2 — both ends</summary>

checkout has to put the context into the message, while a checkout span is
current. fulfil has to take it out and pass it as `context=` when it starts
`process orders`. Doing only one of the two changes nothing in Tempo.

</details>

<details>
<summary>Solution</summary>

In `/obs/apps/checkout.py`, import `propagate` and put the context in the
message:

```python
from opentelemetry import propagate, trace

def publish(order):
    with tracer.start_as_current_span("publish orders", kind=trace.SpanKind.PRODUCER):
        carrier = {}
        propagate.inject(carrier)
        message = dict(order, trace_context=carrier)
        req = urllib.request.Request("http://broker:8080/publish", data=json.dumps(message).encode(),
                                     headers={"Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=2).read()
```

In `/obs/apps/fulfil.py`, start the consumer span from it:

```python
def handle(message):
    order = json.loads(message)
    ctx = propagate.extract(order.pop("trace_context", {}))
    with tracer.start_as_current_span("process orders", context=ctx, kind=trace.SpanKind.CONSUMER) as span:
        ...
```

Nothing was wrong with any tracer. Every service exported every span. The
context simply had no way across the queue.

### The ways this goes wrong

- **Injecting into the headers of the publish request.** It is the HTTP
  pattern, and it is right for an HTTP hop. broker reads the body and drops
  the headers, so fulfil never sees them. For a real broker, put the
  context in the message's own headers, not the client's connection.
- **Injecting at one end only.** checkout's context sits in every message and
  fulfil still starts a root span. Or fulfil extracts from a message that has
  nothing in it, which gives an empty context, which also starts a root span.
  Neither half shows up in Tempo until both are done.
- **A span link instead of a parent.** The consumer's trace links to the
  producer's, and Grafana shows the link. It is still two traces, and a search
  for the order's trace finds half of it. A link is for a span that has many
  causes, such as a batch of messages.
- **`tracer.start_span` instead of `start_as_current_span`.** The span has the
  right parent, but it is not current. When `record()` injects the context for
  ledger, it injects whatever is current, which is nothing. So ledger falls
  out of the trace.
- **Pointing the exporter somewhere else.** Sending fulfil's spans through the
  Collector instead of straight to Tempo changes where they go, not which
  trace they are in.

</details>
