---
title: "The postmortem"
---

## The situation

This is the incident you ran in incident-command: checkout's payment step
failing for most of an hour on 14 November, ended by rolling back the 09:55
deploy. It is over, and the chat (`/ha/sre/postmortem/chat.log`) has already
reached its verdict: "erin's change again. she should have load tested it."

If that is the postmortem, the next one will be the same. The change passed
review. It passed the canary. Nothing alerted on the thing that broke, and
the rollback, once decided, took fourteen minutes. Each of those was true
before erin made the change and is still true now.

The data is in `/ha/sre/postmortem/`: checkout's error counts minute by
minute, the deploy log, the page log, the chat, and who is on the team.

## Your objectives

Write `/ha/answers/postmortem.txt`:

1. When the impact started, when it was detected, when it was resolved, and
   how many checkouts failed because of it, from the data.
2. A timeline from before anyone knew to after customers were fine.
3. The contributing factors: the conditions that let it happen and let it
   last.
4. Action items that change those conditions, each with one owner and a
   date.

## What you're being graded on

- the four numbers match the data: impact from the first minute above the
  usual 0.2%, detection at the page, resolution when the errors were back
  to normal, and the failed checkouts over the baseline;
- the timeline includes the deploy, the first failures, the page, the
  rollback starting and the resolution, in order;
- no blame anywhere: no judgement of a person, no "human error";
- at least three contributing factors, none of them a person, covering why
  it was not caught and why it lasted, not only what triggered it;
- at least three actions, each with one named owner from the team and a
  date, none of them asking someone to be more careful.

## Try it yourself

Read `errors.csv` before the chat. The chat is what people remember; the
data is what customers got.

<details>
<summary>Hint 1 — when it started</summary>

The page at 10:00 is when the team found out. Customers found out earlier:
find the first minute whose failures are above 0.2% of its checkouts. For
the count, take each minute from then to the last bad one, subtract the 0.2%
that fail on any day, and add up the rest.

</details>

<details>
<summary>Hint 2 — conditions, not culprits</summary>

For each thing a person did, ask what made it the reasonable thing to do at
the time. A reviewer approved a "config only" change: what would have shown
them it was not? The canary passed: what did it not exercise? The rollback
took fourteen minutes: what is a rollback, here? The answers are the
factors, and each one suggests its own action.

</details>

<details>
<summary>Solution</summary>

```
impact_start: 09:56
detected: 10:00
resolved: 10:52
failed_checkouts: 11836

timeline: 09:55 | checkout v412 deployed: payment client pool max 20 -> 4, per process
timeline: 09:56 | checkout failures rise above the usual 0.2% (4%)
timeline: 10:00 | CheckoutErrorRate pages at 8%
timeline: 10:04 | bob acknowledges the page
timeline: 10:05 | incident declared SEV2; alice commands, bob operates, carol communicates
timeline: 10:18 | error rate 41%; raised to SEV1
timeline: 10:35 | payment client connection pool found exhausted since the 09:55 deploy
timeline: 10:38 | decision to roll back; rollback (a rebuild of v411) starts
timeline: 10:44 | error rate 3% and falling
timeline: 10:52 | rollback complete; error rate back to 0.2%; resolved

factor: the pool size is set per process, and nothing in the config or its review shows that each process serves many workers
factor: the canary runs at low traffic and never exercises the payment step, so it passed a change that only fails under load
factor: no alert or dashboard watches payment client pool saturation; the first signal was customer-facing errors
factor: rollback is a rebuild of the previous version, so the decision at 10:38 took 14 minutes to reach customers

action: alice | payment client refuses to start if pool max is below its worker count | 2026-11-28
action: bob | canary runs a synthetic checkout through the payment step, at peak-like concurrency | 2026-12-05
action: bob | alert on payment pool wait time and saturation, before customer errors | 2026-11-28
action: gita | keep the previous build's image so rollback is a redeploy, not a rebuild, and time it | 2026-12-12
```

### Why no names in the factors

The timeline names people, because it records who did what. The factors do
not, because a person is never the condition that needs fixing: the
reviewer saw "config only", the canary said zero errors, and anyone on the
team would have approved it. Write "erin should have load tested it" and
the next erin stops telling you what she changed. Write "nothing shows a
reviewer that the pool is per process" and the next reviewer sees it.

### Why one owner each

"SRE team" will not do the alert; bob will, by the 28th, or he will say he
cannot and it gets reassigned in the open. An action without one name and a
date is a wish that is still open at the next incident.

</details>
