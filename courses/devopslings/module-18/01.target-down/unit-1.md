---
title: "shop is running, and Prometheus has never heard of it"
---

## The situation

shop serves customers all day. Its dashboard is empty. Open
<http://localhost:19090/targets> and there is no shop on the page at all, not
even a red one.

Someone restarted Prometheus. Nothing changed, because nothing about
Prometheus was broken. It is doing exactly what its config says.

shop's targets are not written into `prometheus.yml`. The deploy pipeline
publishes them in `/obs/prometheus/targets/shop.json`, and rewrites that file
on every deploy:

```json
[
  {"targets": ["shop:8080"], "labels": {"env": "prod", "team": "storefront"}},
  {"targets": ["legacy-shop:8080"], "labels": {"env": "retired", "team": "storefront"}}
]
```

`legacy-shop` was decommissioned last month. The pipeline still lists it.

## How a target gets scraped

A target goes through three steps between "listed somewhere" and "has
data":

1. **Discovery.** Prometheus reads the targets file (or asks Kubernetes, or
   Consul) and gets an address plus some labels.
2. **Relabelling.** `relabel_configs` run on each discovered target. They can
   rewrite its labels, change the address it is scraped on, or drop it.
3. **Scraping.** Prometheus fetches `http://<address>/metrics`. The result
   becomes the `up` series: `1` if the scrape worked, `0` if it did not.

A target dropped at step 2 never reaches step 3, so it has no `up` series and
no row on the Targets page. Nothing is red, because nothing failed. To see
it, open **Status → Service discovery**: it lists every discovered target,
the labels it arrived with, and whether relabelling kept or dropped it.

## Your objectives

1. Get shop scraped and `up` on its metrics port.
2. Keep reading targets from the pipeline's file. Do not edit that file: the
   pipeline overwrites it.
3. Keep `legacy-shop` out.

Edit `/obs/prometheus/prometheus.yml`, then run `obs-reload`. A restart is
never needed; `obs-reload` tells you if Prometheus rejects the file.

## What you're being graded on

Before the check runs, the pipeline deploys again: shop now runs on two
hosts, `shop:8080` and `shop-2:8080`, and the targets file is rewritten. The
check then requires:

- both shop hosts scraped under `job="shop"`, and `up`
- shop's series still carry `env="prod"` and `team="storefront"` from the file
- no scrape of `legacy-shop`

<details>
<summary>Hint 1 — why it is dropped</summary>

Status → Service discovery shows shop under the `shop` job with
`env="prod"`, marked dropped. Read the relabel rule. `action: keep` keeps a
target only if the regex matches the whole value of the source label. What
value does the rule expect, and what value does shop have?

</details>

<details>
<summary>Hint 2 — once it is on the Targets page</summary>

Now shop is there and red, and the error says `404`. Something answered,
which means the host and port are reachable, and it is not a metrics
endpoint. `8080` is shop's storefront. Look at the end of `/obs/apps/shop.py`
for the port it serves metrics on.

You cannot change the port in the targets file. Relabelling can: a rule with
`target_label: __address__` rewrites the address Prometheus scrapes.

</details>

<details>
<summary>Solution</summary>

```yaml
  - job_name: shop
    file_sd_configs:
      - files: ["/obs/prometheus/targets/*.json"]
        refresh_interval: 5s
    relabel_configs:
      - source_labels: [env]
        regex: prod
        action: keep
      # Discovery publishes the service port; shop serves metrics on 9101.
      - source_labels: [__address__]
        regex: '([^:]+):\d+'
        replacement: '${1}:9101'
        target_label: __address__
```

There were two faults, and the second was hidden behind the first.

**The filter dropped everything.** It kept targets whose `env` was
`production`. No target has that value; shop's is `prod`. So the filter that
was meant to drop the retired host dropped shop too. A dropped target makes no
noise: no `up` series, so no `up == 0` alert either. That is why "the target
is down" alerts miss this kind of failure, and why Service discovery is the
first page to read when a target is missing rather than red.

**The address was the service port.** Deploy tooling usually knows the port a
service listens on, not the port its metrics are on. Rewriting `__address__`
in relabelling is the standard fix. Kubernetes setups do the same thing with
a `prometheus.io/port` annotation.

### The wrong fixes

- **Deleting the filter** gets shop scraped, and `legacy-shop` along with it,
  as a target that is down forever. Every "target down" alert then fires for a
  host that does not exist, and people learn to ignore that alert.
- **Writing `shop:9101` into `static_configs`** works until the next deploy.
  The pipeline added `shop-2` and Prometheus never saw it.
- **Editing the targets file** works until the pipeline rewrites it.

</details>
