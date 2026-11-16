---
title: "The page that nobody owns"
---

## The situation

Every alert in this company pages the platform team. At 02:10 it was
`ServiceErrorRate` for `ledger`. The on-call opened `/obs/services/OWNERS.csv`,
paged payments, and payments spent twenty minutes establishing that ledger
moved to finance in a reorg last year. Forty minutes in, the right team
started looking.

Each service already says who owns it, in the file next to its code:

```
$ cat /obs/services/ledger/service.yaml
name: ledger
owner: finance
tier: 1
```

and the platform already exports that file as a metric, on every scrape:

```
$ promq 'service_info'
{service="checkout",team="payments",...}  1
{service="ledger",team="finance",...}  1
{service="notifications",...}  1
{service="search",team="discovery",...}  1
```

Nothing reads it. `notifications` has no owner at all, and the pipeline that
shipped it, `/obs/platform/pipeline`, checked that its YAML parses.

## Your objectives

1. When a service's error rate alert fires, it pages the team its
   `service.yaml` names, and nobody else.
2. Routing comes from that metadata. When a service changes owner in its
   `service.yaml`, the next page goes to the new team with no other edit.
3. `/obs/platform/pipeline SERVICE` fails for a service with no owner, or an
   owner that is not a team in `/obs/platform/teams.yml`.

## Getting started

You work in the `box` container. The files:

| file | what it is |
|---|---|
| `/obs/prometheus/rules/services.yml` | the alert |
| `/obs/alertmanager/alertmanager.yml` | the routing; each team already has a receiver |
| `/obs/platform/teams.yml` | the teams that can own a service |
| `/obs/platform/pipeline` | what CI runs before a service ships |

`obs-reload` applies Prometheus and Alertmanager changes. Pages land in the
sink, which records the receiver's URL path:

```
curl -s sink:8080/notifications | jq '.[] | {path, status: .payload.status, labels: .payload.commonLabels}'
```

To make a service fail, `touch /obs/run/sim-ledger.fault`; remove the file to
stop. The traffic and `service_info` come from a simulator,
`/obs/apps/gateway_exporter.py`. It is a model, and the check refuses to run
if it was edited.

## What you're being graded on

- With `checkout` and `ledger` failing, checkout's page reaches only the
  `payments` receiver and ledger's only `finance`.
- The check changes `search`'s owner to `payments` in its `service.yaml`,
  makes it fail, and its page has to reach only `payments`.
- `pipeline notifications` fails, `pipeline` fails for a service owned by a
  team that does not exist, and passes for one owned by `finance`.
- The three owned services' `service.yaml` files still name their original
  owners.

<details>
<summary>Hint 1 — the label the alert does not have</summary>

Alertmanager routes on the alert's labels, and `ServiceErrorRate` has
`service` and `severity`. The team is on a different series, `service_info`.
PromQL can copy a label from one series onto another that shares a label:
`group_left`.

</details>

<details>
<summary>Hint 2 — which way round the mapping goes</summary>

A route per service (`service="ledger"` → finance) is OWNERS.csv in YAML, and
goes stale the same way. A route per *team* (`team="finance"` → finance)
changes only when a team is created, and the service-to-team mapping stays in
the service's own file.

</details>

<details>
<summary>Hint 3 — the pipeline</summary>

Read `owner` from `service.yaml` and look it up in `teams.yml`. The pipeline
already has Python and PyYAML. A non-empty owner is not enough: a team name
with a typo is a page that goes nowhere.

</details>

<details>
<summary>Solution</summary>

The alert takes the team from `service_info`:

```yaml
expr: |
  (
    sum by (service) (rate(http_requests_total{job="platform",code="500"}[30s]))
      / sum by (service) (rate(http_requests_total{job="platform"}[30s])) > 0.05
  )
  * on (service) group_left (team) max by (service, team) (service_info{job="platform"})
```

Alertmanager routes by team, with the platform pager as the default for an
alert that has none:

```yaml
routes:
  - matchers: ['team="payments"']
    receiver: payments
  - matchers: ['team="finance"']
    receiver: finance
  - matchers: ['team="discovery"']
    receiver: discovery
```

The pipeline gains a step before `lint`:

```python
owner = meta.get("owner")
if not owner:
    sys.exit("has no owner")
if owner not in teams:
    sys.exit(f"owner '{owner}' is not a team in /obs/platform/teams.yml")
```

### Why the spreadsheet is always wrong

An ownership list kept apart from the services is updated by people who have
no reason to update it at the moment of change. A reorg moves ledger; the
team moving it edits ledger, its pipeline and its dashboards, and nobody's
task is the spreadsheet. Metadata that lives in the service's own repository
is edited in the same change, reviewed by the same people, and the platform
reads it rather than copying it.

### Why the pipeline is where ownership is enforced

The page for a service with no owner arrives months after the service
shipped, at night, to someone who has never heard of it. The only moment
when ownership is cheap to establish is before the first deploy, when the
team that wants to ship is right there. A pipeline check makes "who owns
this?" a question answered once, at that moment.

### In practice

Backstage's `catalog-info.yaml` with `spec.owner`, Kubernetes labels exported
by kube-state-metrics as `kube_*_labels`, and an `app_info` metric are all
this pattern: the owner travels with the service, and the alert joins it in.

</details>
