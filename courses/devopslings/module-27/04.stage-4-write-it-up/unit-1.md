---
title: "Write it up: the postmortem and the runbook"
---

## The situation

Two things happened to checkout. In stage 2 a fault went into the path from
a commit to `www`, somebody noticed, and a fix shipped. In stage 3 a chaos
experiment pushed a release and killed a replica under load, and measured
what customers got. Both stages wrote down when each step happened, in an
event log inside the ops container:

```console
$ docker exec devopslings-ha-ops cat /var/lib/capstone/events.log
```

Each line is a UTC time, the stage, the event and a detail. Stage 3's
`experiment_end` line carries the p99 latency and the share of the error
budget the experiment burned. If you have not run stages 2 and 3 in this
sandbox, the scenario writes a plausible log of both so that you can still
do this stage. A copy is in `scratch/stage-4-write-it-up/events.log`.

Production is still serving on ha-stack: your replicas from the earlier
stages, or stand-ins at the same names and addresses when there are none.
Nothing in the system needs to change. What is missing is the write-up.

## Your objectives

In `scratch/stage-4-write-it-up/`, which the scenario seeds with templates:

1. `postmortem.md`, the postmortem of both: a timeline from the log, the
   impact in the SLO's own terms, the conditions that let it happen, and
   actions that change those conditions.
2. `runbook.md`, what the next on-call follows when `www` is failing: who
   holds which role, what makes an incident SEV1 or SEV2, and the commands
   that find and fix the problem.

## What you're being graded on

The postmortem is graded by the rubric from 24/13, the postmortem:

- **Timeline.** Under `## Timeline`, one entry per line as
  `- YYYY-MM-DD HH:MM UTC  what happened`, in order. Every event in the log
  for the last stage 2 and stage 3 runs needs an entry within two minutes
  of when it was recorded: the fault going in, its detection if the log
  has one, the fix, the experiment's start, release, killed replica and end.
- **Impact.** `## Impact` gives the p99 and the error budget burned, the
  numbers `experiment_end` recorded, as a measure against the SLO.
- **Contributing factors.** At least three, one of them about why it was
  not caught sooner, none of them a person. Nowhere in the postmortem is
  anyone blamed.
- **Action items.** At least three, each as `- owner | what | YYYY-MM-DD`,
  with one owner from `team.txt`, a date after the incident, and a change
  to the system rather than a request to try harder.

The runbook is graded by 24/09, incident command, and then run:

- It names the incident commander, the operations lead and the
  communications lead, and defines at least two severities, each by a
  number the SLO is written in: an error rate, a p99 or a budget burn.
- **Every command in a `sh`, `bash`, `shell` or `console` block is run**,
  from the host, in `scratch/stage-4-write-it-up/`, against ha-stack alone.
  `sh` blocks run whole, with `bash -e`; `console` blocks run their `$ `
  lines. Each block must exit 0 within 60 seconds, and there must be at
  least three commands.
- **Production must still be serving when the runbook is done.** A step may
  restart a replica or fail over a load balancer, since that is what
  runbooks are for, but the runbook as a whole has to leave both replicas
  UP on both load balancers and `www` answering. A step that removes
  something needs the step that puts it back, and a step that waits needs
  a limit. The check puts production back before it runs your runbook and
  after one that broke it.
- A step that needs something ha-stack does not have, such as a rollback
  through the pipeline, goes in a `text` block. It is not run: write it so
  that it would be, with no blank left for the reader to fill in.

Each "not yet" names the line, the number or the block that failed.

<details>
<summary>Hint 1: the timeline</summary>

Copy the times from `events.log`, not from memory, and keep them in UTC.
The log's detail column says which fault stage 2 drew; the timeline is
where you say what it meant. Other entries, such as when an incident was
declared or a cause found, are welcome between the logged ones.

</details>

<details>
<summary>Hint 2: commands that survive being run</summary>

Try each block yourself, from the scratch directory, before you check.
`docker logs -f` and `watch` never return; `docker logs --tail 50` does.
`docker restart capstone-shop-1` is safe if the next step waits for shop1
to be UP again before anything touches shop2; `docker rm -f` is not,
because nothing in ha-stack will put the replica back.

</details>

<details>
<summary>Solution</summary>

`solution/solve.sh` writes both files from the log. The postmortem, for a
log in which stage 2 drew drift:

```markdown
## Impact

During the experiment checkout's p99 latency was 233 ms, and it burned
7.5% of the 30-day error budget against the 99.9% availability SLO.
The fault itself was live for 48 minutes, from 2026-11-18 02:33 UTC to 2026-11-18 03:21 UTC.

## Timeline

- 2026-11-18 02:33 UTC  the drift fault goes into the commit-to-www path
- 2026-11-18 02:38 UTC  the symptom is first noticed
- 2026-11-18 03:21 UTC  the fix ships through the pipeline and the fault's own check passes
- 2026-11-18 04:15 UTC  stage 3's chaos experiment starts: constant-rate load against www
- 2026-11-18 04:18 UTC  a release is pushed through the pipeline under load
- 2026-11-18 04:21 UTC  a replica is killed under load
- 2026-11-18 04:25 UTC  the experiment ends: p99 233 ms, error budget burn 7.5%

## Contributing factors

- A replica removed outside the pipeline left production smaller than its code, and nothing compared the two.
- No alert watched the symptom: the fault was found by a person looking, not by a page.
- The fix could only reach production through a full pipeline run, so time to repair was bounded by build and deploy time.

## Action items

- marco | page on the checkout error rate and p99 burn rate against the SLO | 2026-11-25
- priya | add the fault's own check to the pipeline, so the release is refused while it fails | 2026-12-02
- sam | add a health check that exercises what an order needs, and a test for it | 2026-12-02
- priya | keep a rollback image and a one-command redeploy of the previous digest | 2026-12-18
```

The runbook's roles and severities, and one of its steps:

````markdown
## Roles

- incident commander: decides and coordinates; does not debug or change systems.
- operations lead: investigates and changes the system.
- communications lead: writes every status update.

## Severity

- SEV1: more than 25% of requests to www failing, or more than 10% of the 30-day error budget burned in an hour.
- SEV2: 1-25% of requests failing, or p99 over 500 ms for 5 minutes.

## Restart one replica, and wait until it is back in rotation

```sh
docker restart capstone-shop-1
for i in $(seq 30); do
  st=$(docker exec devopslings-ha-ops curl -fsS --max-time 2 'http://lb1:8404/stats;csv' \
         | awk -F, '$1 == "app" && $2 == "shop1" { print $18 }')
  [ "$st" = UP ] && break
  sleep 1
done
[ "$st" = UP ]
```
````

### The part worth remembering

**A postmortem is written from the record.** Memory compresses, reorders
and rounds. The log says when, the measurement says how bad, and the
postmortem is where somebody says what it meant.

**A runbook nobody has run is a guess.** Commands rot as the system
changes around them. Running every one against the real thing, and
checking the system is still up afterwards, is the only test a runbook
gets before the night it is needed.

</details>
