---
title: "forty panels, and nobody can say whether shop is up"
---

## The situation

Open <http://localhost:13000/d/shop>. "Shop overview" has forty panels:
latency in four flavours, every route, the database, the workers, Python's
garbage collector, Prometheus itself. Each panel was added during some
incident by someone who wanted that one number.

During last week's incident, on-call opened it with three questions and
could not answer any of them quickly:

1. **Is shop serving customers?** How many requests per second?
2. **What fraction of those requests fail?**
3. **How slow are the slowest 1% of requests?** The p99 latency.

Some panels that looked right were not. The "Error ratio" panel adds prod
and staging together. "Requests per second (prod)" can only ever show prod.
There is no p99 panel, only p50, p90 and p95.

The usual response is to add a panel for whatever was missing. That is how
the dashboard got to forty.

## A dashboard is an answer to questions

A good operational dashboard starts from the questions its reader will ask,
and has one panel per answer. Everything else costs the reader time: they
have to look at each panel, decide it does not matter, and move on, during
an incident.

shop runs in two environments. Prometheus scrapes them as `env="prod"` and
`env="staging"`. One dashboard should serve both through a **template
variable**: a drop-down at the top whose value replaces `$env` in every
query.

The dashboard is the file `/obs/grafana/dashboards/shop.json`. Grafana
rereads it every 5 seconds. You cannot save changes in Grafana's UI for a
provisioned dashboard. You can edit a panel there, open **Inspect → Panel
JSON** to see what it produced, and copy that into the file.

## Your objectives

Edit `shop.json` so that:

1. it has a variable named `env` that offers `prod` and `staging`
2. each of the three questions is answered by a panel, for the selected
   environment
3. every panel says which question it answers through its unit (Grafana's
   `fieldConfig.defaults.unit`): `reqps` for requests per second,
   `percentunit` (or `percent`) for the fraction failing, `s` (or `ms`) for
   latency
4. no panel is left that answers none of the three

Keep the uid `shop`. That is the link in on-call's runbook.

## What you're being graded on

The check reads the dashboard from Grafana's API, not from the file, so what
it grades is what Grafana actually loaded. Then:

- the `env` variable offers `prod` and `staging`
- for each panel, it runs the panel's query with `env` set to `prod` and
  compares the result with the answer Prometheus gives to the question the
  panel's unit names
- with `env` set to an environment that does not exist, the panel shows no
  data. A panel that still shows data is not filtering on `$env`.
- with `env` set to `staging`, the panel has data
- all three questions are answered, and every panel answers one of them

<details>
<summary>Hint 1 — the variable</summary>

```json
"templating": {"list": [{
  "name": "env", "type": "query",
  "datasource": {"type": "prometheus", "uid": "prometheus"},
  "query": "label_values(shop_http_requests_total, env)",
  "refresh": 2
}]}
```

`label_values(metric, label)` lists the values of a label that a metric has,
so a third environment shows up on its own. In a query, use it as
`{env="$env"}`.

</details>

<details>
<summary>Hint 2 — the three queries</summary>

```
sum(rate(shop_http_requests_total{env="$env"}[$__rate_interval]))

sum(rate(shop_http_requests_total{env="$env",code=~"5.."}[$__rate_interval]))
  / sum(rate(shop_http_requests_total{env="$env"}[$__rate_interval]))

histogram_quantile(0.99,
  sum by (le) (rate(shop_http_request_duration_seconds_bucket{env="$env"}[$__rate_interval])))
```

`$__rate_interval` is Grafana's choice of a window that always holds enough
samples for `rate()`. Inside JSON, the quotes in a query are written `\"`.

</details>

<details>
<summary>Solution</summary>

`solution/solve.sh` writes the whole file. Its panels:

```json
{"type": "stat", "title": "Is shop serving? Requests per second",
 "fieldConfig": {"defaults": {"unit": "reqps"}},
 "targets": [{"expr": "sum(rate(shop_http_requests_total{env=\"$env\"}[$__rate_interval]))"}]},
{"type": "stat", "title": "What fraction fails?",
 "fieldConfig": {"defaults": {"unit": "percentunit"}},
 "targets": [{"expr": "sum(rate(shop_http_requests_total{env=\"$env\",code=~\"5..\"}[$__rate_interval])) / sum(rate(shop_http_requests_total{env=\"$env\"}[$__rate_interval]))"}]},
{"type": "timeseries", "title": "How slow is the slowest 1%? p99 latency",
 "fieldConfig": {"defaults": {"unit": "s"}},
 "targets": [{"expr": "histogram_quantile(0.99, sum by (le) (rate(shop_http_request_duration_seconds_bucket{env=\"$env\"}[$__rate_interval])))"}]}
```

Three panels, each titled with the question it answers, and each in the unit
of its answer. A number without a unit makes the reader stop and work out
whether 0.4 means seconds, a fraction, or requests.

The other thirty-seven panels are still worth having somewhere. Database,
worker and Prometheus panels belong on their own dashboards, which a link can
reach once one of these three answers says where to look. A dashboard for a
service answers "is it working for customers"; one for a component answers
"why not".

### The ways this goes wrong

- **Adding a p99 panel and keeping the other forty.** The answer is on the
  dashboard, as panel forty-one.
- **No `env` filter.** A sum without it adds prod and staging together. The
  error ratio of the sum can look healthy while prod alone is failing, if
  staging is busy and healthy.
- **Hard-coding `env="prod"`.** Correct for prod, and the drop-down then does
  nothing to that panel.
- **Errors per second instead of a fraction.** 0.5 errors per second is
  either a disaster or nothing, depending on traffic. The fraction is the
  same at any traffic level.
- **p95 or the average instead of p99.** The average of a long-tailed latency
  is close to the median. The customers having the worst time are the ones
  the average hides.

</details>
