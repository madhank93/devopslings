---
title: "the payments gateway has no exporter, so write one"
---

## The situation

The payments gateway is a vendor product. Finance wants a graph of payments
processed and failed, and an alert when the gateway stops answering. The
gateway has no `/metrics`. It has two things:

- a status page, `http://gateway:8080/status`:

  ```json
  {"payments": {"processed": 183402, "failed": 2117}, "queue_depth": 12}
  ```

  The counts run from the day the gateway was installed.

- a log, `/obs/logs/payments.log`, one line per payment, rotated every minute.

The usual first idea is to count lines in the log. The log only holds the
last minute or two, and a line counter starts again from zero every time it
restarts. The status page already has the number you want.

So you write an **exporter**: a small process that reads the gateway's
status when Prometheus scrapes it and serves the result in Prometheus's
format. Prometheus already scrapes `gateway-exporter:9101` as
`job="gateway"`. The exporter's source is `/obs/apps/gateway_exporter.py`,
which does nothing yet. Saving it restarts it, and its output, tracebacks
included, goes to `/obs/logs/gateway-exporter.log`.

## What a good exporter gets right

- **Types.** A count that only goes up is a *counter*, and its name ends in
  `_total`. A level that goes up and down, like a queue depth, is a *gauge*.
  `rate()` and `increase()` need counters.
- **Help text.** Every metric carries a sentence that says what it measures.
  `promtool check metrics` checks for it, along with naming rules.
- **Reading at scrape time.** The numbers should be as fresh as the scrape.
  An exporter that reads the source once when it starts keeps serving those
  first numbers forever.
- **Failing well.** The source is sometimes down, and sometimes so slow that
  waiting for it would take longer than Prometheus is willing to wait for a
  scrape (`scrape_timeout`, 4 seconds here). If the exporter fails its scrape
  then, Prometheus marks the whole target down and every series it served goes
  stale, including the one that says what is wrong. The exporter should keep
  answering, and report a gauge such as `gateway_up 0`.

`prometheus_client` is installed. Its `Counter` can only be incremented,
because it counts events that happen in your own process. The gateway keeps
its own count, so you need a **custom collector**: a class with a `collect()`
method, registered with `REGISTRY.register(...)`, that yields
`CounterMetricFamily` and `GaugeMetricFamily` objects built from whatever it
just read. `collect()` runs on every scrape.

## Your objectives

Serve, on port 9101:

```
gateway_payments_processed_total   counter  the gateway's processed count
gateway_payments_failed_total      counter  the gateway's failed count
gateway_queue_depth                gauge    the gateway's queue depth
gateway_up                         gauge    1 if /status answered this scrape, 0 if not
```

## What you're being graded on

- `promtool check metrics` finds nothing wrong with what the exporter serves
- the four metrics exist with the types above
- the two counts match the gateway's status page, and keep matching ten
  seconds later
- with the gateway **stopped**, Prometheus still scrapes the exporter, and
  `gateway_up` is 0
- with the gateway's status page taking **8 seconds** to answer, the same is
  true
- once the gateway is back, `gateway_up` returns to 1 without a restart

<details>
<summary>Hint 1 — the shape of a collector</summary>

```python
from prometheus_client import start_http_server
from prometheus_client.core import REGISTRY, CounterMetricFamily, GaugeMetricFamily

class GatewayCollector:
    def collect(self):
        # read http://gateway:8080/status here, then:
        yield CounterMetricFamily("gateway_payments_processed", "help text", value=...)
        ...

REGISTRY.register(GatewayCollector())
start_http_server(9101)
```

`CounterMetricFamily` adds `_total` to the name for you. After
`start_http_server` the main thread has to stay alive, for example with a
`time.sleep` loop.

</details>

<details>
<summary>Hint 2 — when the gateway does not answer</summary>

`urllib.request.urlopen` without a `timeout=` waits as long as the server
takes. Pass one that is well under the 4-second scrape timeout. Wrap the fetch
in `try`/`except`, and when it fails, yield only `gateway_up` with value 0.

Do not yield the counters as 0. To Prometheus a counter that drops to zero has
reset, so when the gateway comes back, `increase()` counts every payment since
installation as if it happened in that minute.

</details>

<details>
<summary>Solution</summary>

```python
import json, time, urllib.request
from prometheus_client import start_http_server
from prometheus_client.core import REGISTRY, CounterMetricFamily, GaugeMetricFamily


class GatewayCollector:
    def collect(self):
        up = GaugeMetricFamily("gateway_up", "1 if the gateway's status page answered this scrape, else 0.")
        try:
            s = json.load(urllib.request.urlopen("http://gateway:8080/status", timeout=2))
        except Exception:
            up.add_metric([], 0)
            yield up
            return
        up.add_metric([], 1)
        yield up
        yield CounterMetricFamily("gateway_payments_processed", "Payments processed since the gateway was installed.",
                                  value=s["payments"]["processed"])
        yield CounterMetricFamily("gateway_payments_failed", "Payments that failed since the gateway was installed.",
                                  value=s["payments"]["failed"])
        yield GaugeMetricFamily("gateway_queue_depth", "Payments waiting to be processed.", value=s["queue_depth"])


REGISTRY.register(GatewayCollector())
start_http_server(9101)
while True:
    time.sleep(3600)
```

An alert on the gateway is now `gateway_up == 0`, and it fires on a gateway
that is down as well as on one that is too slow to be useful.

### The ways this goes wrong

- **Counting log lines.** The count starts over with every restart of the
  exporter and every rotation of the log. The gateway already keeps the real
  count.
- **A gauge for the counts**, because `Gauge.set()` was the only way to put
  someone else's number into `prometheus_client`. The values look right, and
  `rate()` and `increase()` no longer treat them as counts.
- **No `try`.** The first time the gateway is down, the scrape fails, the
  target goes red, and `gateway_up` disappears along with everything else.
- **No timeout**, or one longer than the scrape timeout. The gateway is slow
  exactly when it is overloaded, which is when you most want its numbers. The
  scrape times out and the exporter looks down instead of the gateway.
- **Zeros while the gateway is down.** That is a counter reset to Prometheus,
  and every graph built on `increase()` spikes when the gateway returns.
- **Reading once at startup**, or caching without a refresh. The numbers are
  right for the first minute and frozen after.

</details>
