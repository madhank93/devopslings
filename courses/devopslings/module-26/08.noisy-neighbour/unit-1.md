---
title: "One team's backfill, everyone's queue"
---

## The situation

Four teams share one pool of eight CI runners. Web, api and payments submit
builds at a steady trickle. Then the data team starts a backfill: 160 builds
at once. They all go into one first-come, first-served queue, and for the next
forty seconds nobody else's build starts.

The top request on `/obs/platform/BOARD.md`, 14 votes, is more runners. The
budget is eight. The second request is to ban daytime backfills, and the data
team's one vote says their backfill has a window it has to finish in.

## Your objectives

1. Through a 160-build burst from data, web, api and payments keep getting
   their builds done at the rate they submit them.
2. The data team's backfill still drains, within two minutes.
3. Stay on 8 runners.
4. Write the decision to `/obs/answers/noisy-neighbour.txt`: the mechanism
   you chose, and two you rejected, each with a reason:

   ```
   chosen: <mechanism> | <why>
   rejected: <mechanism> | <why not, in this pool>
   rejected: <mechanism> | <why not, in this pool>
   ```

## Getting started

You work in the `box` container. The pool is `/obs/platform/runners.yml`. Its
comments list what the scheduler supports: fair sharing, a per-tenant
concurrency cap, and dedicated pools. The scheduler is a simulator,
`/obs/apps/gateway_exporter.py`, that rereads the file every tick. It is a
model, and the check refuses to run if it was edited.

Start a burst and watch who gets runners:

```
touch /obs/run/sim-burst
promq 'sum by (tenant) (rate(runner_jobs_completed_total[20s]))'
promq 'runner_queue_depth'
```

## What you're being graded on

- `runners:` is still 8.
- The check starts a burst. Over the next 25 seconds, web, api and payments
  each finish nearly every build they submit.
- Data's queue is empty within two minutes.
- `chosen:` names the mechanism `runners.yml` is configured with, and the two
  `rejected:` lines name two other mechanisms, each with a reason of at least
  six words.

<details>
<summary>Hint 1 — why the others wait</summary>

With one FIFO queue, a build waits for every build that arrived before it.
160 builds at two seconds each on eight runners is forty seconds of queue in
front of the next web build. More runners shorten it; they do not stop the
next, bigger backfill putting everyone behind it again.

</details>

<details>
<summary>Hint 2 — the three options</summary>

All three keep the other teams moving through this burst. The difference is
what happens when nobody else is busy. A cap or a dedicated pool limits data
to its slice even when the rest of the pool is idle. Fair sharing lets data
use every runner nobody else is asking for, and gives one back the moment
someone does.

</details>

<details>
<summary>Solution</summary>

```yaml
runners: 8
scheduler: fair
```

```
chosen: fair share scheduling | each tenant's builds start in proportion to its share, so a burst queues behind itself and still uses every idle runner
rejected: more runners | the budget is 8, and a bigger pool only drains the same head-of-line queue faster; the next backfill is bigger
rejected: dedicated pools | runners reserved for data sit idle between backfills, and the backfill is limited to its slice when the pool is quiet
```

### Why "add runners" is the wrong first move

The problem is ordering, not capacity. Eight runners serve the steady load
with room to spare; the burst is 160 builds arriving in one instant. Any pool
size short of 160 still puts the other teams behind it, and the backfill
grows with the data.

### What each isolation mechanism costs

- **Fair share** keeps the pool fully used: a lone tenant gets all of it, and
  each competing tenant gets its share. It costs a scheduler that knows who
  each build belongs to.
- **A concurrency cap** is one number, easy to reason about, and wastes
  capacity: data is held at its cap with runners idle.
- **Dedicated pools** isolate completely, including failures, and waste the
  most: each pool's idle runners cannot help the other.

### In practice

Per-project concurrency limits in hosted CI and Kubernetes ResourceQuota per
namespace are caps; the Kubernetes API server's priority and fairness, and
YARN's fair scheduler, are fair sharing. The decision is the same each time:
how much idle capacity you will pay for isolation.

</details>
