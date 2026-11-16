---
title: "Access logs carry one field that dashboards need as three"
---

## The situation

The edge proxy sends one log record per request to the Collector. Each
record has a single attribute:

```
request = "GET /payments/charge 503"
```

The dashboards are built on OpenTelemetry's HTTP conventions and want three
attributes, typed:

| attribute | type | example |
|---|---|---|
| `http.request.method` | string | `GET` |
| `url.path` | string | `/payments/charge` |
| `http.response.status_code` | int | `503` |

`request` itself should be gone once it has been split.

Someone has started on this in `/obs/otel/collector.yaml`. Their transform
splits the field into `method`, `path` and `status`. Since it went live,
whole batches of the proxy's records have gone missing. Not
every record the proxy sends is well formed. The proxy truncates long lines,
logs a startup message with no `request` at all, and one old client sends the
status as a number.

The Collector writes what it exports to `/obs/otel/out/access.jsonl`, one
OTLP JSON document per export. `/obs/otel/sample-access.json` is a batch with
two good records and three bad ones:

```
curl -H 'Content-Type: application/json' http://collector:4318/v1/logs -d @/obs/otel/sample-access.json
tail -n 1 /obs/otel/out/access.jsonl | jq '.resourceLogs[].scopeLogs[].logRecords[] | {body, attributes}'
```

## OTTL

The **transform** processor runs OTTL (OpenTelemetry Transformation
Language) statements on every record:

```yaml
transform/request:
  error_mode: ignore
  log_statements:
    - context: log
      statements:
        - set(attributes["x"], "y")
        - set(attributes["n"], Int(attributes["s"])) where attributes["s"] != nil
```

The functions you need are `ExtractPatterns(value, "regex with (?P<name>…)
groups")`, which returns a map, `merge_maps(target, map, "upsert")`,
`set(target, value)`, `Int(value)`, `delete_key(attributes, "k")` and
`delete_matching_keys(attributes, "regex")`. Named groups cannot contain
dots, so extract to plain names and `set` the dotted ones.

**`error_mode`** decides what a failing statement does:

- `propagate` (the default): the error goes back up the pipeline, and the
  whole batch the record arrived in is rejected. The receiver answers 503.
  The client retries the same batch, it fails again, and the good records in
  it never arrive.
- `ignore`: the error is logged, and the record continues with whatever the
  statements managed to do. That avoids losing the batch, and lets a
  half-transformed record through.

The **filter** processor drops records that match an OTTL condition:

```yaml
filter/name:
  error_mode: ignore
  logs:
    log_record:
      - 'not IsString(attributes["request"])'
```

`IsString(x)` and `IsMatch(x, "regex")` are conditions, and `not`, `and` and
`or` combine them.

## Your objectives

Change the processors in `/obs/otel/collector.yaml` so that:

- every well-formed record leaves with exactly the three schema attributes,
  correctly typed, and no `request`
- every malformed record is dropped
- a malformed record never costs the good records in its batch

## What you're being graded on

The check sends one batch of 16 records, 12 well formed and 4 malformed
(truncated, missing, a number, empty), and reads what the Collector
exported:

- the Collector accepts the batch
- all 12 good records come out with `http.request.method`, `url.path` and
  `http.response.status_code` (an integer) matching the input, and no other
  attributes
- none of the 4 malformed records come out

<details>
<summary>Hint 1 — the missing batches</summary>

Send the sample batch and look at what `curl` gets back. Then look at
`/obs/logs/collector.log`.

</details>

<details>
<summary>Hint 2 — drop first</summary>

A transform cannot drop a record. A filter can. If the filter runs first and
drops everything the transform cannot parse, the transform only sees records
it can handle. Keep `error_mode: ignore` on the transform anyway, in case a
record gets past the filter.

</details>

<details>
<summary>Solution</summary>

```yaml
processors:
  filter/malformed:
    error_mode: ignore
    logs:
      log_record:
        - 'not IsString(attributes["request"]) or not IsMatch(attributes["request"], "^[A-Z]+ \\S+ \\d{3}$")'
  transform/request:
    error_mode: ignore
    log_statements:
      - context: log
        statements:
          - merge_maps(attributes, ExtractPatterns(attributes["request"], "^(?P<method>[A-Z]+) (?P<path>\\S+) (?P<status>\\d{3})$"), "upsert")
          - set(attributes["http.request.method"], attributes["method"])
          - set(attributes["url.path"], attributes["path"])
          - set(attributes["http.response.status_code"], Int(attributes["status"]))
          - delete_matching_keys(attributes, "^(method|path|status|request)$")
…
      processors: [filter/malformed, transform/request]
```

The filter's regex and the transform's regex describe the same shape. A
record that passes the filter is one the transform can parse.

### The ways this goes wrong

- **Leaving `error_mode: propagate`.** One record with a numeric `request`
  fails `ExtractPatterns`, and the whole batch is rejected with a 503. The
  client retries the same batch, which fails the same way. That is the
  missing batches: a batch without a bad record gets through, and a batch with
  one never does.
- **`error_mode: ignore` and no filter.** Nothing is lost. The truncated
  line, the startup message and the numeric one all go through. Some have no
  attributes at all, and some still have `request`. A dashboard counts them
  as requests with no method.
- **Status as a string.** `http.response.status_code >= 500` is then a
  string comparison, or an error, depending on where it runs.
- **Keeping `request`.** Every record now carries the same information
  twice. And nobody can tell which copy is authoritative once someone changes
  one of them.
- **A filter after the transform.** The transform has already failed the
  batch before the filter runs.

</details>
