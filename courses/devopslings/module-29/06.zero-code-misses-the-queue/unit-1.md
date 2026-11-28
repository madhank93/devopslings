---
title: "Zero-code tracing sees the request and not the job it queued"
---

## The situation

fulfil takes orders on `POST /orders`, answers `202 Accepted` at once, and
puts a job on a queue. A worker thread takes the job off and does the real
work: it reserves the stock and prints the label, a few hundred milliseconds
in all.

fulfil has no tracing code. It runs under **opentelemetry-instrument**,
OpenTelemetry's zero-code agent for Python: the launcher block at the top of
`fulfil.py` re-runs the file under it, and the agent patches Flask and
urllib as they load. Every request to fulfil is a span in Tempo.

```
curl -s -XPOST fulfil:8080/orders -H 'Content-Type: application/json' -d '{"sku":"A1"}'
curl -s 'http://tempo:3200/api/search' -G --data-urlencode 'q={resource.service.name="fulfil"}' | jq
```

Each trace is one span of a couple of milliseconds. The slow part, the part
customers complain about, is not in any trace.

The team's first guess is a missing instrumentation package: there must be
one for queues, or threads.

The source is `/obs/apps/fulfil.py`. Saving it restarts fulfil; its output is
in `/obs/logs/fulfil.log`.

## What zero-code instrumentation covers

The agent instruments **libraries**: Flask, urllib, requests, psycopg, and
the rest of a long list. It wraps their functions as they are imported, so
every request handled and every call made through them gets a span, with the
context taken from incoming headers and put on outgoing ones.

It knows nothing about your own code. fulfil's worker loop is a
`queue.Queue` and a `while True:` that fulfil wrote; no package can know
where a job starts and ends in it. That part is manual: get a tracer and
start a span.

```python
from opentelemetry import trace

tracer = trace.get_tracer("fulfil")
with tracer.start_as_current_span("..."):
    ...
```

Under the agent, `trace.get_tracer` returns a tracer from the provider the
agent already set up, so the span goes wherever the request spans go.

## Context does not cross threads by itself

The **current context** (which span is active) is held per thread. While
Flask runs `accept()`, the current span is the request's. The worker thread
was started at boot and has no current span, so a span started there with no
other instructions is the root of a new trace.

The job has to carry the context across. `opentelemetry.context` gives you
the current one as an object:

```python
from opentelemetry import context

ctx = context.get_current()        # in the handler
...
with tracer.start_as_current_span("...", context=ctx):   # in the worker
```

When the queue is a broker between two processes, you cannot put an object
on it. Then `propagate.inject(carrier)` writes the context into a dict as
headers, and `propagate.extract(carrier)` reads it back on the other side.

## Your objectives

Make each order one trace: the request span from the agent, and under it a
span that covers the worker's job. Keep fulfil under opentelemetry-instrument,
and keep `POST /orders` answering `202` before the job runs.

## What you're being graded on

The check sends 5 orders, each with a W3C `traceparent` header of its own, so
it knows each request's trace ID. In each of those traces it looks for:

- the Flask request span the agent made, as a child of the check's span
- below it, a span that lasts at least 250ms, which only the job does

<details>
<summary>Hint 1 — the job's span is in a trace of its own</summary>

If your span shows up in Tempo as a root, with no parent, it started without
the request's context. Look at what the worker can see when it starts it.

</details>

<details>
<summary>Hint 2 — the span is there and lasts 2ms</summary>

A span started in `accept()` ends when `accept()` returns, long before the
worker picks the job up. Start the span in the worker.

</details>

<details>
<summary>Solution</summary>

```python
from opentelemetry import context, trace

tracer = trace.get_tracer("fulfil")


def worker():
    while True:
        job = JOBS.get()
        with tracer.start_as_current_span("fulfil order", context=job["ctx"]):
            reserve_stock(job["order"])
            print_label(job["order"])
        JOBS.task_done()


@app.post("/orders")
def accept():
    job = {"id": uuid.uuid4().hex, "order": request.get_json(silent=True) or {},
           "ctx": context.get_current()}
    JOBS.put(job)
    return {"job": job["id"]}, 202
```

Grafana shows the request span ending after a couple of milliseconds and the
job's span starting under it and running on long after: the order's real
latency, which no request-duration metric had ever shown.

### The ways this goes wrong

- **Installing more instrumentation.** There is nothing for a hand-written
  queue loop. `opentelemetry-instrumentation-threading` carries context into
  threads started *after* the request, and this worker started at boot.
- **A span in the worker, with no context.** Each job becomes its own trace,
  and nothing connects it to the order that caused it. The check finds those
  traces and says so.
- **The span in the handler, around `JOBS.put`.** In the right trace, and it
  measures the enqueue: a couple of milliseconds.
- **`context.get_current()` in the worker.** That is the worker thread's
  context, which is empty. It has to be taken in the handler.

</details>
