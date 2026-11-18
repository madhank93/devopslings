---
title: "The platform is up, and nobody can ship"
---

## The situation

The platform's SLO is availability: every component answering its health
check. It has been 100% all week.

```
$ promq 'platform:availability:ratio'
{}  1
```

In the same week, a one-line fix took 55 minutes to reach production and the
release manager stood up at the all-hands to say so. `/obs/platform/SLO.md`
already states the objective the platform is supposed to meet:

> 99% of changes reach production within 30 minutes of the push, over a
> rolling hour.

Nothing measures it. The forge, the runners, the registry and the deployer
each report healthy, so the dashboard is green whatever a developer is
living through.

## Your objectives

1. Record `platform_journey:sli:ratio_1m`: the fraction of changes, over the
   last minute, that reached production within 30 minutes. One series.
2. Record `platform_journey:error_budget_remaining:1h`: how much of the hour's
   error budget is left against the 99% objective. 1 is untouched, 0 is spent,
   below 0 is overspent.
3. On the seeded bad day, every component stays healthy and the SLI drops.

## Getting started

You work in the `box` container. The rules live in
`/obs/prometheus/rules/platform-slo.yml`; `obs-reload` applies them.

The data comes from a simulator, `/obs/apps/gateway_exporter.py`. It is a
model and the check refuses to run if it was edited. Look at what it exports:

```
curl -s gateway-exporter:9101/metrics | grep -v '^#' | sort | head -40
```

To see the bad day it models, `touch /obs/run/platform.degrade`; remove the
file to end it. Watch what moves and what does not.

## What you're being graded on

- Both series exist, one series each, and the rule files are loaded.
- On a normal minute the SLI is near 1.
- With `/obs/run/platform.degrade` in place and every component healthy, the
  SLI is below 0.9.
- The budget matches the good-journey count over the last hour against a 99%
  objective, within 10%.

<details>
<summary>Hint 1 — which metrics describe the journey</summary>

`platform_component_up`, `platform_http_requests_total` and
`ci_builds_total` describe parts of the platform. Only two metrics describe a
change on its way to production: `platform_journeys_total`, every change that
finished, and `platform_journey_duration_seconds`, how long the ones that
deployed took.

</details>

<details>
<summary>Hint 2 — counting "within 30 minutes"</summary>

A histogram bucket counts observations at or below its `le`. The 1800-second
bucket is the number of changes that deployed within 30 minutes. Divide its
rate by the rate of *every* journey, failed ones included: a change that never
deployed did not make it in 30 minutes either.

</details>

<details>
<summary>Hint 3 — the budget</summary>

Allowed bad fraction is `1 - 0.99`. Spent is the actual bad fraction over the
hour divided by the allowed one. Remaining is `1 - spent`. Use `increase(...[1h])`
for the hour, not the one-minute SLI.

</details>

<details>
<summary>Solution</summary>

```yaml
groups:
  - name: platform-slo
    rules:
      # Component health: useful for finding which part broke, not an SLI.
      - record: platform:availability:ratio
        expr: avg(platform_component_up{job="platform"})

      - record: platform_journey:sli:ratio_1m
        expr: |
          sum(rate(platform_journey_duration_seconds_bucket{job="platform",le="1800.0"}[1m]))
            / sum(rate(platform_journeys_total{job="platform"}[1m]))

      - record: platform_journey:error_budget_remaining:1h
        expr: |
          1 - (
            1 - sum(increase(platform_journey_duration_seconds_bucket{job="platform",le="1800.0"}[1h]))
                  / sum(increase(platform_journeys_total{job="platform"}[1h]))
          ) / (1 - 0.99)
```

### Why uptime is the wrong SLI for a platform

Availability answers "is each part running?". Developers do not use parts;
they push a change and wait for it to be in production. On the bad day every
part is running and the runners are all busy: builds wait 40 minutes for one.
No component is down, so no component's SLI moves. The journey's does.

### Why the failed journeys are in the denominator

A ratio of "deployed in time" over "deployed" makes a platform that fails
half the changes look better, because only the survivors are counted. The
journey is "my change reaches production"; one that never got there is a bad
event, not a missing one.

### In practice

This is the same method as module 24, turned on the platform: pick the user,
pick the journey, count good events over valid ones. The components keep
their health checks, for finding *which* part broke once the journey SLO says
something did.

</details>
