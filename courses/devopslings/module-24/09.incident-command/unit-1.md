---
title: "Incident command"
---

## The situation

At 10:00 the checkout error rate pages. By 10:10 there will be three people
in the channel, and without structure all three will open the logs: nobody
will tell support what to say, nobody will notice the error rate quadruple,
and the decision to roll back will be made twice, differently.

The team's criteria are published (`/ha/ic/criteria.md`): how severity is
called, which roles exist, and how often the rest of the company hears from
you. `/ha/ic/timeline.txt` is what happens, minute by minute. Facts arrive
when they are written there; you cannot act on the 10:35 finding at 10:20.
`/ha/ic/people.txt` is who is available.

## Your objectives

Write `/ha/answers/incident.txt`, the incident as you would run it:

1. When it is declared, who holds each role, and when it is resolved.
2. Every severity call, as the facts arrive.
3. Every status update, who posts it, and what it says.
4. Who does what (`task:` lines): investigating, changing systems,
   coordinating, communicating, deciding.

## What you're being graded on

A rubric built from the criteria:

- three roles, three different people who are actually there;
- severity matches the criteria at every minute, is raised within 5 minutes
  of the fact that raises it, and is never lowered before resolution;
- updates by the communications lead, never further apart than the cadence
  in force, plus one at resolution;
- each task is done by the role that owns its kind of work; the commander
  makes at least one decision and never investigates or changes anything.

## Try it yourself

Read the timeline twice: once for the facts that change severity, once for
the moments someone will ask "should I...?".

<details>
<summary>Hint 1 — who commands</summary>

The best debugger in the room is the worst choice for commander, because
the moment the investigation gets interesting, they will want to join it.
Pick the person who will be least tempted, and give the person with the most
context about the system the role that uses it.

</details>

<details>
<summary>Hint 2 — the cadence</summary>

Write down each update's time, and under it the time the next one is due.
When severity goes up, the cadence shortens from that minute, so the next
update may be due sooner than the previous one said.

</details>

<details>
<summary>Solution</summary>

```
declared: 10:05
commander: alice
ops_lead: bob
comms_lead: carol
resolved: 10:52

severity: 10:05 | SEV2
severity: 10:18 | SEV1

update: 10:08 | carol | Some customers cannot complete checkout; investigating. Next update by 10:38.
update: 10:20 | carol | Checkout failing for many customers; raised to SEV1. Next update by 10:35.
update: 10:35 | carol | Cause found in this morning's 09:55 release; preparing to roll back. Next by 10:50.
update: 10:47 | carol | Rollback in progress, most checkouts working again. Next by 11:02.
update: 10:52 | carol | Resolved: checkout is back to normal. A postmortem will follow.

task: 10:05 | alice | coordinate | open the channel, assign roles, set the cadence
task: 10:06 | bob   | investigate | checkout errors: which step, since when
task: 10:06 | carol | communicate | collect and link the support tickets
task: 10:18 | alice | decide | raise to SEV1
task: 10:31 | alice | decide | stays commander; asks bob what he needs from the client's authors
task: 10:38 | alice | decide | roll back the 09:55 deploy
task: 10:38 | bob   | change | roll back the 09:55 deploy
task: 10:52 | alice | decide | declare resolved; postmortem owner: bob
```

### Why alice commands

alice wrote the payment client, and that is exactly why she should not be
the one debugging it while also running the incident. As commander she is
the person who knows which questions bob should be asked. At 10:31 she offers
to pull the logs herself: that is the moment the rubric is about. The answer
is "no, I am commanding", or a clean handover of command to someone else
before she starts, never both.

### SEV2 first

8% of checkouts failing is serious, and it is still SEV2 by the published
criteria. Over-calling feels safe, and it costs: a 15-minute cadence, a
wider page, and a SEV1 label that means less next time. The criteria exist
so the call is the same whoever makes it. 41% at 10:18 makes it SEV1, and the
3% at 10:44 does not make it SEV2 again: a falling error rate during a
half-finished rollback is not a resolved incident.

### dan

The person with the authority is on holiday. An incident structure that
needs the manager to be present is not a structure.

</details>
