#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Agents redact before anything leaves the PCI hosts and route spans by trace
# ID, so each gateway holds whole traces to tail-sample. Both tiers batch and
# queue; the gateway's retry outlasts the vendor's ten-minute outages.
set -euo pipefail
cat > /obs/fleet/agent.yaml <<'YML'
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: localhost:4317

processors:
  memory_limiter:
    check_interval: 1s
    limit_percentage: 80
    spike_limit_percentage: 20
  attributes/pci:
    actions:
      - key: payment.card_number
        action: delete
      - key: user.email
        action: hash
  batch: {}

exporters:
  loadbalancing:
    routing_key: traceID
    protocol:
      otlp:
        tls:
          insecure: true
        retry_on_failure:
          enabled: true
        sending_queue:
          enabled: true
    resolver:
      static:
        hostnames:
          - gateway-1.obs.internal:4317
          - gateway-2.obs.internal:4317
          - gateway-3.obs.internal:4317

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, attributes/pci, batch]
      exporters: [loadbalancing]
YML
cat > /obs/fleet/gateway.yaml <<'YML'
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317

processors:
  memory_limiter:
    check_interval: 1s
    limit_percentage: 80
    spike_limit_percentage: 20
  tail_sampling:
    decision_wait: 10s
    policies:
      - name: errors
        type: status_code
        status_code:
          status_codes: [ERROR]
      - name: the-rest
        type: probabilistic
        probabilistic:
          sampling_percentage: 5
  batch: {}

exporters:
  otlp/vendor:
    endpoint: otlp.vendor.example:4317
    retry_on_failure:
      enabled: true
      max_elapsed_time: 15m
    sending_queue:
      enabled: true
      queue_size: 20000

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, tail_sampling, batch]
      exporters: [otlp/vendor]
YML
cat > /obs/answers/topology.txt <<'TXT'
tail_sampling: gateway — a sampling decision needs every span of the trace, and only a gateway that receives them all, routed by trace ID from the agents, has the whole trace
redaction: agent — card numbers and emails must not leave the PCI host in clear, so they are removed before the first export, before anything crosses the segment
batching: both — each tier exports over the network, and batching turns thousands of per-span requests into a few compressed ones on each hop
retry: both — the agent queues and retries through a gateway restart, and the gateway queues through a vendor outage of up to ten minutes instead of dropping the data
TXT
for f in agent gateway; do otelcol-contrib validate --config=/obs/fleet/$f.yaml; done
