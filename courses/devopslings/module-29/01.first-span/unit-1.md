---
title: "ledger has the OpenTelemetry SDK installed and has never sent a span"
---

## The situation

ledger records the payment entry for every order: `POST /entries` with an
order ID, an amount and a currency. The platform team added the
OpenTelemetry SDK and its OTLP exporter to ledger's image weeks ago. Nobody
wrote any code that uses them, so Tempo has never received a span from
ledger, and a slow entry is invisible.

```
curl -s -XPOST ledger:8080/entries -d '{"order_id":"ord-1","amount":9.5,"currency":"EUR"}' -w '%{http_code}\n'
```

The source is `/obs/apps/ledger.py`. Saving it restarts ledger, and its
output, tracebacks included, is in `/obs/logs/ledger.log`.

## The four pieces of a span

Installing the SDK does nothing by itself. A span reaches Tempo only when
four things are in place, in this order:

1. A **TracerProvider**, with a **Resource** that says which service this
   is. `service.name` is how every tracing tool groups spans. Without it the
   SDK reports `unknown_service`.
2. A **span processor** that hands finished spans to an **exporter**.
   `BatchSpanProcessor` queues them and sends them in batches from a
   background thread, so a request never waits on the network.
   `OTLPSpanExporter` speaks OTLP, the protocol Tempo and the Collector
   receive.
3. A **tracer**, taken from the provider, which creates spans.
4. A **span**: a name, a start, an end, and **attributes**, which are typed
   key-value pairs. A number set as a number can be compared in a query; the
   same number set as a string cannot.

```python
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

provider = TracerProvider(resource=Resource.create({"service.name": "..."}))
provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(endpoint="...")))
trace.set_tracer_provider(provider)
tracer = trace.get_tracer("...")

with tracer.start_as_current_span("...") as span:
    span.set_attribute("...", value)
```

The `with` block starts the span and ends it, so the span's duration is the
time the block took.

Tempo receives OTLP over HTTP at `http://tempo:4318/v1/traces`. The Collector
at `http://collector:4318/v1/traces` forwards whatever it receives to Tempo,
so either endpoint works.

To find a span, use TraceQL, Tempo's query language, in Grafana
(<http://localhost:13000>, Explore, the Tempo datasource) or from the box:

```
curl -s 'http://tempo:3200/api/search' --data-urlencode 'q={resource.service.name="ledger"}' -G | jq
```

## Your objectives

Make ledger send one span per entry to Tempo:

- named `record entry`, covering the work in `record()`
- from service `ledger`
- with the attributes `order.id` (string), `entry.amount` (number) and
  `entry.currency` (string), set from the request

## What you're being graded on

The check sends three entries of its own and then looks them up in Tempo:

- `{name="record entry" && span.order.id="<the order it sent>"}` finds each one
- the span's `service.name` is `ledger`
- `entry.amount` is a number equal to the amount sent, and `entry.currency`
  matches
- ledger still answers `201`

<details>
<summary>Hint 1 — nothing arrives</summary>

Check `/obs/logs/ledger.log` first: a typo in the code means ledger never
started. Then check where the exporter points. `http://tempo:4318` without
`/v1/traces` is a path Tempo does not serve.

</details>

<details>
<summary>Hint 2 — where the span goes</summary>

Set the provider up once, at module level, next to the imports. Start the
span inside `record(entry)`, where `entry` is the parsed body.

</details>

<details>
<summary>Solution</summary>

At the top of `/obs/apps/ledger.py`:

```python
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

provider = TracerProvider(resource=Resource.create({"service.name": "ledger"}))
provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(endpoint="http://tempo:4318/v1/traces")))
trace.set_tracer_provider(provider)
tracer = trace.get_tracer("ledger")
```

And `record()`:

```python
def record(entry):
    with tracer.start_as_current_span("record entry") as span:
        span.set_attribute("order.id", entry["order_id"])
        span.set_attribute("entry.amount", float(entry["amount"]))
        span.set_attribute("entry.currency", entry["currency"])
        time.sleep(0.01)
        ENTRIES.append(entry)
```

### The ways this goes wrong

- **`ConsoleSpanExporter`.** It is the first exporter in most tutorials. It
  prints each span to stdout, which here is `/obs/logs/ledger.log`, and sends
  nothing anywhere.
- **No Resource.** The span arrives in Tempo as `unknown_service:python3`,
  and a search by service never finds it.
- **The amount as a string.** `str(entry["amount"])` or an f-string makes
  `"42.5"`. It looks the same in Grafana and fails every numeric comparison.
- **`SimpleSpanProcessor`.** It works here. It also exports each span
  synchronously, inside the request, so every request waits on Tempo. Use the
  batch processor in a service.
- **Starting the span after the work.** A span opened and closed after
  `ENTRIES.append` measures nothing. The `with` block has to contain the work.

</details>
