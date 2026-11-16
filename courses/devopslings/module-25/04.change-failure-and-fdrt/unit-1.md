---
title: "Six incidents, and not all of them were your deploys"
---

## The situation

The incident tracker exported the quarter's incidents to
`scratch/change-failure-and-fdrt/incidents.csv`. Six rows, every one with a
`suspected_deploy` filled in, because on-call fills that field in when the
page fires: it is whatever deployed last.

The quarterly review wants two numbers from it. **Change failure rate**: the
share of production deployments that caused a failure needing remediation.
**Failed Deployment Recovery Time**: how long it took to recover from those.
DORA renamed the second one from MTTR in 2025, and narrowed it. It covers
failures a deployment caused, and nothing else.

The first draft of the review counted all six incidents.

## Your objectives

1. Decide which incidents a deployment caused, and exclude the rest.
2. Compute the change failure rate over the quarter's production deployments.
3. Compute the median recovery time over the failed deployments, in minutes.

Write them in `scratch/change-failure-and-fdrt/answer.txt`.

## What you're being graded on

The excluded incidents must be exactly the ones no deployment caused. The
change failure rate must be within half a percentage point; a fraction such as
`0.143` is accepted. The median recovery time must be within five minutes of
the value computed from the deploy tags and the CSV.

<details>
<summary>Hint 1 — read the resolution column</summary>

The `suspected_deploy` is a guess made at 2am. The `resolution` is what
actually fixed it. A failure a deployment caused is fixed by changing what is
deployed: a revert, a fix, a rollback. Something that recovered with nothing
deployed was not caused by a deployment.

</details>

<details>
<summary>Hint 2 — when the failure started</summary>

The incident's `detected_at` is when somebody noticed. For a failed
deployment, customers had the bug from the moment the deployment went out.
Recovery time runs from the failed deployment to the resolution:

```
git for-each-ref --format='%(refname:short) %(taggerdate:iso)' refs/tags/deploy/production/413
```

</details>

<details>
<summary>Solution</summary>

```
excluded=INC-102,INC-104
change-failure-rate=14.3
recovery-median-minutes=140
```

- **INC-102** is a power loss in the colo. The suspected deploy had been
  running for eleven hours, and the hosts came back when the power did.
- **INC-104** is the payment provider's own outage. It hurt customers; nothing
  of checkout's changed, and nothing was deployed to fix it.

The other four were each fixed by deploying a revert or a fix: four failed
deployments out of 28 is 14.3%. Counting all six gives 21%, and blames the
delivery process for a datacentre.

Recovery for each runs from the failed deployment's tag date to `resolved_at`.
Measured from `detected_at` instead, the median is 85 minutes: shorter,
because it leaves out the time the bug was live and nobody had noticed.

### The part worth remembering

**Change failure rate and Failed Deployment Recovery Time are delivery
metrics.** They ask how often your changes break production and how quickly
your delivery process undoes it. An outage with no change behind it is real,
and it belongs to reliability — your SLOs and error budgets — where it is
measured against every cause, not just your own deploys.

Mixing them makes both worse. The delivery numbers move for reasons the team
cannot act on through its pipeline, and the reliability work gets argued about
in a deployment review instead of in the place where it can be fixed.

The `suspected_deploy` column is the trap to remember. It is filled in before
anybody knows what happened, it is always the most recent deploy, and a
dashboard that joins on it will attribute every outage to a change.

</details>
