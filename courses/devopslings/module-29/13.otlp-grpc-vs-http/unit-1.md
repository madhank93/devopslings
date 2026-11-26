---
title: "billing exports spans and the Collector gets none"
---

## The situation

billing is new, and its team turned tracing on: one span per invoice, a
batch exporter, and the Collector's OTLP port as the destination. A day later
Tempo has nothing from it:

```
curl -s 'http://tempo:3200/api/search?q={resource.service.name="billing"}&limit=5' | jq '.traces | length'
```

The source is `/obs/apps/billing.py`; saving it restarts billing, and what
the exporter says about each failed export is in `/obs/logs/billing.log`.
The Collector's config is `/obs/otel/collector.yaml`.

## Two transports, two ports

OTLP is one data model with two transports, and by convention each has its
own port:

| Port | Transport | What arrives |
|---|---|---|
| 4317 | gRPC (HTTP/2, protobuf) | calls to `opentelemetry.proto.collector.trace.v1.TraceService/Export` |
| 4318 | HTTP/1.1 | `POST /v1/traces` with a protobuf or JSON body |

They are not interchangeable. A gRPC server answering on 4317 does not
understand an HTTP/1.1 `POST /v1/traces`, and an HTTP server on 4318 does not
understand an HTTP/2 gRPC call. Neither side says "wrong protocol": the
exporter logs a connection reset, a malformed response, or an unavailable
status, and retries until it gives up.

The SDKs pick the exporter from `OTEL_EXPORTER_OTLP_PROTOCOL` (`grpc`,
`http/protobuf` or `http/json`) and the address from
`OTEL_EXPORTER_OTLP_ENDPOINT`. With the HTTP exporter, that endpoint is a
base URL and `/v1/traces` is appended; the per-signal
`OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` is used as given, path and all. The
two settings are usually set in different places — the protocol in a
platform default, the endpoint in the service's deploy config — which is how
they drift apart.

## Your objectives

1. Fill in `/obs/answers/otlp-ports.txt`: which protocol each port speaks.
2. Get billing's spans into Tempo through the Collector, with the exporter's
   protocol and the port it sends to agreeing. Change billing, not the
   Collector's receiver.

## What you're being graded on

- the answer: 4317 is gRPC, 4318 is HTTP
- the Collector's `otlp` receiver still listens for gRPC on 4317 and HTTP on
  4318
- billing's spans arrive in Tempo, and the Collector's `otlp` receiver
  counts them as accepted on the way

<details>
<summary>Hint 1 — reading the failure</summary>

`grep -iE 'export|error' /obs/logs/billing.log | tail`. Which exporter class
is in the traceback, and what is it talking to?

</details>

<details>
<summary>Hint 2 — two ways to make them agree</summary>

Either keep the port and change the protocol, or keep the protocol and
change the port. Both are one line in `billing.py`.

</details>

<details>
<summary>Solution</summary>

billing sends `http/protobuf` to `collector:4317`, the gRPC port. Make them
agree, either way:

```python
os.environ["OTEL_EXPORTER_OTLP_PROTOCOL"] = "grpc"
os.environ["OTEL_EXPORTER_OTLP_ENDPOINT"] = "http://collector:4317"
```

or

```python
os.environ["OTEL_EXPORTER_OTLP_PROTOCOL"] = "http/protobuf"
os.environ["OTEL_EXPORTER_OTLP_ENDPOINT"] = "http://collector:4318"
```

and in `/obs/answers/otlp-ports.txt`:

```
4317: grpc
4318: http
```

Which to choose: gRPC is the default in most SDKs and streams efficiently
between hosts you control; HTTP passes through ordinary proxies, load
balancers and browsers, and is the only choice for a browser SDK.

### The ways this goes wrong

- **gRPC to 4318.** The mirror image of the original bug; nothing arrives.
- **Swapping the Collector's receiver ports.** billing works, and every
  other service using the defaults breaks. The check rejects it.
- **`OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://collector:4318`.** The
  per-signal endpoint is used as given, so the exporter posts to `/` and
  gets a 404; it needs `/v1/traces` on the end.
- **Sending straight to Tempo.** Tempo speaks both, so spans arrive — around
  the Collector, where the fleet's sampling and redaction live. The check
  rejects it.

</details>
