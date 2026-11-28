---
title: "The log says the payment failed, and nothing leads to the request that failed"
---

## The situation

payments charges cards for orders, four at a time. Every request is a trace
in Tempo, and every step is a JSON record in Loki, in the stream
`{service="payments"}`:

```json
{"ts": "2026-11-23 10:14:02,118", "level": "error", "msg": "payment failed", "order_id": "ord-31234501", "reason": "issuer unavailable"}
```

Support has the line and wants to see what the request did: how long the
card network took and what it answered. The trace has that. The line has no
way to reach it. Searching Tempo for the second around the line finds a
dozen payments in flight, and the one you want is not marked.

payments' source is `/obs/apps/lab.py`; it runs in the `lab` container,
saving the file restarts it, and its own errors are in `/obs/logs/lab.log`.
Grafana's datasources are provisioned from
`/obs/grafana/provisioning/datasources/`. Grafana reads them at start, and
again when told to:

```
curl -u admin:admin -X POST http://grafana:3000/api/admin/provisioning/datasources/reload
```

## Joining a log to its trace

The join is the **trace id**. Every span in a request's trace carries it, and
while the request is being handled the SDK holds that request's span as the
**current span**. A log record written then belongs to that trace. Writing
the id into the record makes the relationship explicit:

```python
from opentelemetry import trace

ctx = trace.get_current_span().get_span_context()
ctx.trace_id        # an int, 128 bits
format(ctx.trace_id, "032x")   # how Tempo and a W3C traceparent write it
```

Outside any span, `get_current_span()` returns a placeholder whose trace id
is 0. `ctx.is_valid` tells you which one you have.

The place to do it is where every record passes through, not in each `log`
call. In Python's `logging` that is the formatter, or a `logging.Filter` that
sets an attribute on the record. Both run in the thread that called `log`, so
the current span is the request's. The OpenTelemetry SDK's logging
integration does the same thing for records it exports over OTLP.

Then Grafana has to turn the id into a link. On a Loki datasource that is a
**derived field**: a regex run over each line, whose first capture group is
the value, and a link built from it. A link to another datasource names it by
uid, and the link's `url` is the query to run there. For Tempo the query is
the trace id itself:

```yaml
datasources:
  - name: Loki
    uid: loki
    type: loki
    url: http://loki:3100
    jsonData:
      derivedFields:
        - name: TraceID
          matcherRegex: '<regex with one capture group>'
          url: '$${__value.raw}'
          datasourceUid: tempo
```

`${__value.raw}` is the captured value, as captured. Grafana expands `$NAME`
and `${NAME}` in a provisioning file from its own environment, so the file
writes `$$` for a literal `$`. In Explore each matching line then shows a
button that opens the trace beside it.

## Your objectives

1. Make every record payments logs carry `trace_id`: the trace id of the
   request it was logged in, as 32 hex digits.
2. Give Grafana's Loki datasource a derived field that opens that trace in
   Tempo.

## What you're being graded on

The check reads what payments sent to Loki since it last restarted:

- every record has a `trace_id` of 32 hex digits, and none is all zeros
- the trace of each recent `payment failed` record is in Tempo, and it is
  that payment's request: its order id is on the span
- Grafana's Loki datasource, as Grafana has it loaded, has a derived field
  whose regex captures the trace id from a failure line and whose link opens
  exactly that id in the `tempo` datasource

<details>
<summary>Hint 1 — the formatter</summary>

`JsonFormatter.format` builds a dict and dumps it. One more key, read from
`trace.get_current_span()`, puts the id on every record.

</details>

<details>
<summary>Hint 2 — the regex</summary>

Run it against a real line. `json.dumps` writes `"trace_id": "…"` with a space
after the colon. In YAML, a single-quoted string keeps the double quotes and
backslashes inside it as they are.

</details>

<details>
<summary>Solution</summary>

```python
class JsonFormatter(logging.Formatter):
    def format(self, record):
        rec = {"ts": self.formatTime(record), "level": record.levelname.lower(),
               "msg": record.getMessage()}
        rec.update(getattr(record, "fields", {}))
        ctx = trace.get_current_span().get_span_context()
        if ctx.is_valid:
            rec["trace_id"] = format(ctx.trace_id, "032x")
        return json.dumps(rec)
```

```yaml
  - name: Loki
    uid: loki
    type: loki
    access: proxy
    url: http://loki:3100
    jsonData:
      derivedFields:
        - name: TraceID
          matcherRegex: '"trace_id": "([0-9a-f]{32})"'
          url: '$${__value.raw}'
          datasourceUid: tempo
```

```
curl -u admin:admin -X POST http://grafana:3000/api/admin/provisioning/datasources/reload
```

In Explore, a `payment failed` line now has a TraceID link, and the trace it
opens has the failed `card network authorise` span with the decline reason on
it.

### The ways this goes wrong

- **`str(ctx.trace_id)`.** A 39-digit decimal. Tempo knows no such id.
- **The span id instead of the trace id.** It names one span, and Tempo looks
  up traces.
- **Starting a span in the formatter to read an id from.** The id belongs to
  a trace with nothing else in it, and that span is never exported.
- **Logging after the `with` block closes.** The request's span is no longer
  current, and the record gets the all-zero id, or none.
- **A derived field with `url: http://tempo:3200/api/traces/${__value.raw}`
  and no `datasourceUid`.** That is an external link to Tempo's raw JSON API,
  not the trace view, and it only works from a browser that can reach
  `tempo:3200`.
- **Editing the file and not reloading.** Grafana keeps what it loaded.
- **`url: '${__value.raw}'` in the provisioning file.** Grafana reads it as
  an environment variable, finds none, and stores an empty link.

</details>
