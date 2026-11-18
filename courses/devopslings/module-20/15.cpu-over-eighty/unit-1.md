---
title: "Paged for a busy CPU, silent for a broken cart"
---

## The situation

`shop` has one paging alert, in `/obs/prometheus/rules/capacity.yml`:

```yaml
- alert: ShopCPUOver80
  expr: rate(process_cpu_seconds_total{job="shop"}[30s]) > 0.8
  for: 30s
```

Its week went like this:

- **Tuesday, 03:10.** The nightly search-index rebuild ran, shop used a full
  core for a while, and the alert paged. Every customer request was served, as
  fast as usual. Someone got up for nothing.
- **Thursday, 14:00.** A migration took a lock on `db`. Every `/cart` and
  `/orders/:id` request waited on it and failed. Shop's CPU sat near zero,
  because shop was doing nothing but waiting. Nothing paged for twenty
  minutes, until a customer emailed.

You can make both happen on purpose, from the `box` container:

```
touch /obs/run/shop.rebuild     # the rebuild; rm the file to stop it
touch /obs/run/db.fault         # the migration's lock
echo 0.3 > /obs/run/shop.fault  # a bug in shop: 30% of requests fail
```

Every alert pages. What paged, and when, lands in the sink:

```
curl -s sink:8080/notifications | jq '.[] | {path, status: .payload.status, alerts: [.payload.alerts[].labels.alertname]}'
```

## Causes and symptoms

CPU is a **cause**: one of many things that can be behind a problem, and often
behind no problem at all. A busy CPU might mean customers wait, or it might
mean the machine is doing exactly the work you bought it for. An idle CPU
might mean all is well, or that every request is stuck waiting on something
else.

What customers get is the **symptom**: requests that fail, and requests that
are slow. Every cause that matters ends up there, including the ones nobody
has thought of yet, and a cause that does not end up there did not hurt
anyone.

So page on symptoms. Keep cause metrics like CPU on dashboards, and for
non-paging warnings about capacity, where they help you find out why once the
symptom alert has woken you.

Shop exports what you need: `shop_http_requests_total`, with a `code` label,
and `shop_http_request_duration_seconds`, a histogram.

## Your objectives

Replace `ShopCPUOver80` with an alert that pages when shop's customers are
being hurt, whatever the cause, and stays quiet when they are not. Leave no
silences behind.

## What you're being graded on

The check first waits for a quiet minute, and nothing may be firing. Then it
runs three rounds, waiting for a page in each:

1. The rebuild burns a core for 100 seconds. Nothing may page.
2. `db` is locked. Something must page within 150 seconds.
3. Shop fails 30% of its requests on its own, with `db` healthy. Something must
   page within 150 seconds.

It takes about seven minutes.

<details>
<summary>Hint 1 — the shape of the expression</summary>

The share of requests that fail: the rate of requests with a `5xx` code,
divided by the rate of all requests, summed across routes. A raw count of
errors grows with traffic; a ratio does not.

</details>

<details>
<summary>Hint 2 — choosing the threshold</summary>

Query the ratio on a normal day. It should be zero or close to it. Pick a
threshold well above that and well below what either fault produces, and give
it a `for:` long enough that one unlucky scrape does not page.

</details>

<details>
<summary>Solution</summary>

`/obs/prometheus/rules/capacity.yml`:

```yaml
groups:
  - name: shop-customers
    rules:
      - alert: ShopRequestsFailing
        expr: |
          sum(rate(shop_http_requests_total{code=~"5.."}[1m]))
            / sum(rate(shop_http_requests_total[1m])) > 0.05
        for: 30s
        labels:
          severity: page
        annotations:
          summary: more than 5% of shop requests are failing
```

Then `obs_reload` (from `. /usr/local/lib/obs.sh`), or POST to Prometheus's
`/-/reload`.

### In production

- The errors half of this is one of the four golden signals; the other half
  worth paging on is latency, as a p99 or a share of slow requests over an
  SLO's threshold. Both are measured where customers are, at the load
  balancer or the service's edge.
- Keep a CPU or saturation alert if you want one, routed to a ticket, not a
  pager: "this will be a problem next week" is worth knowing in daylight.
- When an outage happens and no symptom alert fires, the gap is in what you
  measure, not in the threshold of a cause alert.

</details>
