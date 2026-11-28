---
title: "checkout speaks B3, fulfil reads traceparent, and every order is two traces"
---

## The situation

`POST /checkout` on checkout calls fulfil, and fulfil calls ledger, all over
HTTP. The three services run under opentelemetry-instrument, which traces
Flask and urllib with no code in the services and puts the trace context on
every outgoing call.

Every order shows up in Tempo as two traces: one with checkout's spans, and
one, starting a few milliseconds later, with fulfil's and ledger's.

```
curl -s -XPOST checkout:8080/checkout
curl -s 'http://tempo:3200/api/search' -G --data-urlencode 'q={}' | jq '.traces[] | {rootServiceName, rootTraceName}'
```

The team's first guess is that fulfil's tracer is broken. It is not: fulfil
and ledger share one trace, so fulfil's outgoing context works and ledger
reads it. Something about the call from checkout is different.

In module 19's `broken-trace` the context was lost at an async hop. There is
no async hop here, and the context is on the call. fulfil and ledger print
the headers of every request they receive:

```
grep headers /obs/logs/fulfil.log | tail -1
```

The sources are `/obs/apps/{checkout,fulfil,ledger}.py`. Saving one restarts
that service.

## Propagators

A **propagator** writes the current trace context into a call's headers, and
reads it back out on the other side. There is more than one format:

| Propagator | Headers |
|---|---|
| `tracecontext` (W3C Trace Context) | `traceparent: 00-<trace id>-<span id>-01`, `tracestate` |
| `b3multi` (Zipkin B3) | `X-B3-TraceId`, `X-B3-SpanId`, `X-B3-Sampled` |
| `b3` (B3 single header) | `b3: <trace id>-<span id>-1` |
| `baggage` (W3C Baggage) | `baggage` |

A service reads only the formats its propagators name. A request that
carries the context in a format it does not read looks, to that service,
like a request with no context: it starts a new trace. Nothing errors and
nothing is logged.

The OpenTelemetry default is `tracecontext,baggage`. Under
opentelemetry-instrument, `OTEL_PROPAGATORS` sets the list; in code,
`opentelemetry.propagate.set_global_textmap()` does. A **composite**
propagator such as `tracecontext,b3multi` writes both formats on the way out
and reads whichever it finds on the way in, which is how a fleet migrates
from one format to the other without breaking traces in between.

## Your objectives

Make each order one trace, holding checkout, fulfil and ledger, by setting
propagators. Keep the services under opentelemetry-instrument.

## What you're being graded on

The check sends 3 orders to checkout, each starting a trace of its own (it
sends both a `traceparent` and B3 headers with the same IDs, so checkout
joins it whatever it reads), and then:

- reads each trace from Tempo and finds spans from all three services
- reads the service sources: none of them writes `traceparent` or `X-B3-*`
  by hand

If a hop is broken, it says which headers the callee received.

<details>
<summary>Hint 1 — what fulfil received</summary>

Compare the headers in `/obs/logs/fulfil.log` with the ones in
`/obs/logs/ledger.log`. One has `traceparent`.

</details>

<details>
<summary>Hint 2 — which side to change</summary>

Either side works: checkout can write what fulfil reads, or fulfil can read
what checkout writes. One of them leaves the fleet on a single format.

</details>

<details>
<summary>Solution</summary>

In checkout's launcher block, the setting left over from Zipkin:

```python
OTEL_PROPAGATORS="tracecontext,baggage",
```

checkout restarts, and the next order is one trace with all three services.

If other services still send B3 to fulfil, give fulfil
`OTEL_PROPAGATORS="tracecontext,baggage,b3multi"` instead (or as well) until
they move over.

### The ways this goes wrong

- **Copying the IDs by hand.** Reading `X-B3-TraceId` in fulfil and
  building a context from it fixes one hop, for one format, and drops the
  sampling decision and baggage on the floor. The check reads the sources
  for it.
- **`b3multi` on fulfil alone.** fulfil now reads checkout's call and writes
  B3 to ledger, which reads only `traceparent`. The break moves one hop
  down. The check names the hop.

</details>
