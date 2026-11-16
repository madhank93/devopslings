---
title: "The Collector is running, and none of storefront's logs reach Loki"
---

## The situation

The platform team has rolled out an OpenTelemetry Collector for logs. Every
service sends OTLP over HTTP to `collector:4318`, and the Collector is meant
to clean the records up and forward them to Loki. It starts without errors.
Loki has nothing from storefront.

The config is `/obs/otel/collector.yaml`. Saving it restarts the Collector,
and everything the Collector prints is in `/obs/logs/collector.log`. Every
component the pipeline needs is already defined in the file.

## How a Collector config fits together

A config has two halves:

1. **Definitions.** `receivers:`, `processors:` and `exporters:` each
   declare components and their settings. A definition on its own does
   nothing.
2. **Pipelines.** `service.pipelines` wires defined components together,
   one pipeline per signal (`logs`, `traces`, `metrics`):

   ```yaml
   service:
     pipelines:
       logs:
         receivers: [otlp]
         processors: [a, b, c]     # run in this order, every record
         exporters: [otlphttp/loki]
   ```

A component that is defined and not listed in a pipeline is never started.
The Collector does not warn about it.

`type/name` gives several components of the same type different names, for
example `otlphttp/loki` and `otlphttp/tempo`.

The order of `processors:` matters, because each one sees what the previous
one produced:

- `memory_limiter` decides whether to accept data at all, so it goes first.
  Further down, the processors ahead of it have already spent the memory it
  was meant to protect.
- Anything that renames or adds attributes has to run before anything that
  matches on them.
- `batch` groups records for the exporter. It goes after anything that drops
  records, so it does not hold records that are then thrown away.

## Your objectives

Fix `/obs/otel/collector.yaml` so that storefront's logs reach Loki:

- received over OTLP/HTTP on port 4318
- stamped with `deployment.environment=prod`
- with `url.path` renamed to `http.route`
- with load balancer health checks (`/healthz`) dropped
- through processors in an order that does what each one is for

`/obs/otel/sample-log.json` holds one ordinary record and one health check,
the way storefront sends them:

```
curl -H 'Content-Type: application/json' http://collector:4318/v1/logs -d @/obs/otel/sample-log.json
logcli query '{service_name="storefront"}' --since=10m
```

Loki turns `service.name` and `deployment.environment` into the labels
`service_name` and `deployment_environment`. Record attributes such as
`http.route` come back with each line as `http_route`.

## What you're being graded on

The check sends a storefront record and a health check to `collector:4318`,
then looks in Loki:

- the record arrives, with `deployment_environment="prod"` and
  `http_route="/cart"`, and no `url_path`
- the health check does not arrive
- `memory_limiter` is the first processor, and `batch` comes after the filter

<details>
<summary>Hint 1 — three faults, then an order</summary>

Send the sample and follow it. Does `curl` connect? Does the Collector log
the record, and where does it send it? Then compare the pipeline's
`processors:` list with the processors that are defined.

</details>

<details>
<summary>Hint 2 — the health check that gets through</summary>

The filter drops records whose `http.route` is `/healthz`. Storefront sends
`url.path`. What is the attribute called at the moment the filter runs?

</details>

<details>
<summary>Solution</summary>

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318
…
service:
  pipelines:
    logs:
      receivers: [otlp]
      processors: [memory_limiter, resource/env, attributes/normalize, filter/healthchecks, batch]
      exporters: [otlphttp/loki]
```

There were three faults that lose data and two orderings that do not:

- **The receiver listened only for gRPC.** storefront speaks OTLP/HTTP, so
  its connection was refused. Nothing showed up in the Collector's log,
  because nothing arrived.
- **The pipeline exported to `debug`.** `otlphttp/loki` was defined and
  never used. The `debug` exporter prints a summary to the Collector's own
  output, which looks like proof that logs are flowing.
- **`resource/env` was not in the pipeline.** Being defined is not enough.
- **The filter ran before the rename.** It matched `http.route`, which did
  not exist yet, so every health check got through. Once the order is
  right, the filter does its job.
- **`memory_limiter` last and `batch` first.** Neither loses data in a quiet
  lab. Under memory pressure, the limiter refuses data only after everything
  ahead of it has already been buffered.

`otelcol-contrib validate --config /obs/otel/collector.yaml` catches a pipeline
that names a component that does not exist. It does not catch a component
that is defined and never used. Neither does anything else.

</details>
