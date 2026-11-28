---
title: "RED metrics for a service nobody will instrument"
---

## The situation

`ledger-legacy` has served the same HTTP API for six years. It has no
OpenTelemetry SDK, its build is not reproducible, and the team that owned it is
gone. Every other service on the dashboard has request rate, error rate and
duration; this one is a gap in every trace that crosses it.

The first guess is to add the SDK. That is a code change, a rebuild and a
redeploy of the one service nobody can rebuild with confidence.

[Grafana Beyla](https://grafana.com/docs/beyla/latest/) instruments from
outside the process. It attaches eBPF programs to the kernel's socket paths
(and, for Go binaries, uprobes on the runtime's HTTP functions), reconstructs
each HTTP request from what it sees, and exports RED metrics and server spans.
The service is not touched, and does not know.

Someone already deployed it. Beyla runs in the `beyla` container, which shares
`ledger-legacy`'s PID namespace — the sidecar pattern — so it can see that
process and nothing else on the host. Its config is `/obs/beyla/beyla.yaml`,
adapted from the payments gateway's, and it restarts when you save the file.
Prometheus scrapes its metrics endpoint as `job="beyla"`, and it sends spans to
Tempo. A week later, `ledger-legacy` is in neither.

## What to look at

- `/obs/logs/beyla.log`: what Beyla found when it started, and which processes
  it decided to instrument. The absence of a line is information too.
- `http://beyla:9400/metrics` from the box: Beyla's own view, before Prometheus
  is involved. `http_server_request_duration_seconds_count` is the request
  counter; its `service_name` label is how dashboards find a service.
- Grafana at `http://localhost:13000`, Explore → Tempo:
  `{resource.service.name="ledger-legacy"}`.
- Send traffic yourself: `curl http://ledger-legacy:9480/entries/42`.

Beyla's [configuration reference](https://grafana.com/docs/beyla/latest/configure/options/)
covers `discovery` and `otel_traces_export`.

## Your objectives

Change `/obs/beyla/beyla.yaml` so that every request `ledger-legacy` serves is
counted in Prometheus and has a server span in Tempo, under the service name
`ledger-legacy`. Do not touch `/obs/apps/ledger_legacy.py`.

## What you're being graded on

The check confirms `ledger_legacy.py` is the original, sends `ledger-legacy` 20
requests, and then requires all three of:

- Beyla's request counter for `service_name="ledger-legacy"` went up by exactly
  20
- Prometheus has those counts
- Tempo has a span for each of the 20 requests

<details>
<summary>Hint 1 — Beyla attached to nothing</summary>

Beyla logs `instrumenting process` with the command and pid of each process it
attaches to. If there is no such line, its discovery rules matched nothing.
`open_ports` selects a process by a port it listens on. Which port does
`ledger-legacy` listen on, and which one does the config name?

</details>

<details>
<summary>Hint 2 — counted, but only some spans</summary>

Metrics count every request; traces go through a sampler first. The config
came from a gateway serving thousands of requests a second, where keeping one
trace in twenty is a cost decision. On a service that serves a few a minute it
loses the one request anyone will ask about. Beyla's default sampler keeps
every trace.

</details>

<details>
<summary>Solution</summary>

`ledger-legacy` listens on 9480, so discovery on 8080 attaches to nothing, and
the 5% ratio sampler drops nineteen of every twenty spans. Select the right
port, name the service, and leave out the sampler so every trace is kept:

```yaml
discovery:
  instrument:
    - open_ports: 9480
      name: ledger-legacy

otel_traces_export:
  endpoint: http://tempo:4318

prometheus_export:
  port: 9400
```

Without `name`, Beyla names the service after the script, `ledger_legacy`.

</details>

## Further reading

- Beyla is the Grafana distribution of
  [OpenTelemetry eBPF Instrumentation](https://opentelemetry.io/docs/zero-code/obi/)
  (OBI), the project Grafana donated it to. The configuration is the same.
- `ebpf-in-production` in this module: what an eBPF agent like this one needs
  from the kernel and the host before it goes on a fleet.
