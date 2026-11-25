---
title: "every request, counted twice"
---

## The situation

A single Prometheus is a single point of failure: when it restarts, nothing
is scraped and nothing is alerted on. The usual answer is a pair, two
identical Prometheus servers scraping the same targets. Each one alone has
the whole picture.

Here the pair is `prometheus-2` (replica a) and `prometheus-3` (replica b),
and both remote-write to **Mimir**, the long-term store that dashboards over
months query. Ask one replica, then Mimir, how many requests loadgen has
made:

```
curl -s prometheus-2:9090/api/v1/query --data-urlencode 'query=sum(loadgen_requests_total)' | jq -r '.data.result[0].value[1]'
curl -s mimir:9009/prometheus/api/v1/query --data-urlencode 'query=sum(loadgen_requests_total)' | jq -r '.data.result[0].value[1]'
```

Mimir says twice as many. Look at why:

```
curl -s mimir:9009/prometheus/api/v1/query --data-urlencode 'query=count by (replica) (loadgen_requests_total)' | jq .
```

Each replica stamps its samples with `replica="a"` or `replica="b"`
(`external_labels` in its config), so Mimir stores two copies of every
series, and every `sum()` adds them up. Turning one replica off would fix the
number and throw away the reason for having two.

## Mimir's HA tracker

Mimir can take a pair's two streams and keep one. Its **HA tracker** reads
two labels off each incoming batch:

- `cluster` names the pair. Samples with the same `cluster` describe the same
  targets.
- `__replica__` names the member of the pair.

For each cluster it elects one replica and accepts only that replica's
samples; the others are acknowledged and dropped. It removes `__replica__`
before storing, so the stored series are the same whichever replica sent
them. If the elected replica stops sending for longer than the failover
timeout (5 seconds here, 30 by default), the next batch from another replica
of that cluster takes over.

The labels are set by the replicas, in `global.external_labels`. They are
added to everything a Prometheus sends out: remote write, alerts, federation.
Mimir here is already configured to track `cluster` and `__replica__`; see
<http://localhost:19009/distributor/ha_tracker> for what it has elected.

## Your objectives

1. Label the pair so Mimir treats prometheus-2 and prometheus-3 as two
   replicas of one cluster.
2. Keep both replicas running and writing to Mimir.

The configs are `/obs/prometheus-2/prometheus.yml` and
`/obs/prometheus-3/prometheus.yml`. After editing one, reload it:

```
curl -X POST prometheus-2:9090/-/reload
curl -X POST prometheus-3:9090/-/reload
```

To stop a replica and start it again: `touch /obs/run/prometheus-2.down`,
`rm /obs/run/prometheus-2.down`.

## What you're being graded on

- both replicas run your config, and both write to Mimir
- both send the same `cluster` and different `__replica__` values
- Mimir has elected a replica, and its `sum(loadgen_requests_total)` is
  within 10% of that replica's own
- the elected replica stops: Mimir switches to the other one within two
  minutes, and the sums still match

<details>
<summary>Hint 1</summary>

Replace `replica: a` with two labels: a `cluster` both files share, and
`__replica__: a`. The same in the other file with `__replica__: b`.

</details>

<details>
<summary>Solution</summary>

`/obs/prometheus-2/prometheus.yml`:

```yaml
global:
  scrape_interval: 5s
  scrape_timeout: 4s
  external_labels:
    cluster: shop-prod
    __replica__: a
```

and `/obs/prometheus-3/prometheus.yml` the same with `__replica__: b`. Reload
both.

`__replica__` starts with two underscores because labels like that are
dropped before storage: in Prometheus's own data model, `__`-prefixed labels
are internal. Mimir strips it after the HA tracker has read it.

### The ways this goes wrong

- **A different `cluster` per replica.** Two clusters, each with one
  replica: nothing to deduplicate, and the sum stays doubled.
- **The same `__replica__` on both.** The HA tracker sees one replica and
  accepts both streams. They have the same labels now, so they collide:
  Mimir rejects one replica's samples as duplicates or out of order, sample by
  sample, and its error logs fill up.
- **Keeping `replica` and adding the two labels.** `replica` is still stored,
  so the two replicas' series still differ — but only one is accepted at a
  time, so a dashboard sees series end and new ones begin at every failover.
- **Stopping one replica.** The numbers are right until the remaining one
  restarts.

</details>
