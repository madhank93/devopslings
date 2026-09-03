---
title: "the bad rule reached every node in forty seconds"
---

## The situation

On 2 July 2019 Cloudflare published a WAF rule containing a pattern that
backtracks catastrophically. Every request that reached a node running it
burned CPU. Forty seconds later every node in the fleet was at 100% and the
service was down worldwide.

The rule passed review. It passed the test suite. It was fatal anyway, because
what was wrong with it was a *cost*, and cost only appears against real traffic.
No amount of pre-merge checking finds that class of defect — which is why the
interesting question is not "how do we catch it earlier" but "how much of the
fleet is allowed to find out at once".

Two things the signals did, and they are the whole design problem:

- `cpu_p95` went from 41 to 97 on any node with the rule — but took about
  thirty seconds of real traffic to get there.
- `http_5xx_per_10k` did not move. The rule made requests *expensive*, not
  *wrong*. Nodes returned correct answers slowly until they saturated
  completely, and that happened after the rollout had finished.

## Your objectives

Write the rollout policy that would have stopped it.

`policy.env` — the stages, the signal, the threshold, the bake time.
`answers/rollout.md` — the written half: what happens to the canary nodes when
a gate fails, why that signal, what the policy costs, and why "roll back
faster" is not an answer.

`./simulate.sh bad` and `./simulate.sh healthy` run your policy so you can try
it. The grader uses its own copy of the harness, so editing that one proves
nothing.

## What you're being graded on

Your policy, executed. It has to halt the bad change having reached no more
than 5% of the fleet, **and** ship the healthy change to all of it. Then the
written fields, with `abort-action` checked against the three options and the
prose checked for having actually been written.

<details>
<summary>Hint 1 — what the first stage is for</summary>

A canary is not a smaller rollout. It is a bet you can afford to lose. The
question to ask of the first stage is not "is this enough traffic to be
representative" but "if every node in this stage is destroyed, is the service
still up".

Those two pull in opposite directions, and the second one wins, because the
first can be recovered by baking longer.

</details>

<details>
<summary>Hint 2 — a gate is only as good as the signal under it</summary>

Two signals were recorded. One of them separates a healthy node from a broken
one and the other reads the same either way.

A gate on a signal that does not respond to the failure is not a partial
safeguard — it is a rollout with extra steps, and it is worse than none,
because it is why nobody looked.

</details>

<details>
<summary>Hint 3 — bake time is a property of the signal, not of your patience</summary>

If you promote before the signal has had time to move, you read a healthy
number off a node that is already broken and promote on the strength of it.

So bake time is not "how long am I willing to wait". It is "how long does this
signal need before its reading means anything", and you get that number from
the incident: about thirty seconds of real traffic.

</details>

<details>
<summary>Hint 4 — the gate has to let good things through</summary>

The grader runs your policy against a healthy change too, and requires it to
reach 100%.

This is not a formality. A gate tuned so tightly that ordinary changes trip it
does not survive contact with a delivery team — it gets bypassed for "this one
urgent thing", and then bypassing it is the normal way to ship. A safeguard
that is routinely disabled has a worse expected outcome than one that was never
built, because the org believes it is protected.

</details>

<details>
<summary>Solution — one defensible policy, not the only one</summary>

There is no single right policy. This one is defensible:

```sh
STAGES=1,5,25,100
SIGNAL=cpu_p95
THRESHOLD=80
BAKE_SECONDS=60
```

One node first, because the only property that stage needs is survivability.
`cpu_p95` because it is the signal that moved. 80 because healthy is 41 and
broken is 97, so it sits well clear of an ordinary busy afternoon while leaving
no room for this. 60 seconds because the signal needs about 30, and a bake that
is exactly as long as the detection latency is a bake that sometimes reads
early.

And `abort-action: revert`, because the gate fired on evidence that those nodes
are unhealthy. Freezing leaves them that way — it converts a global outage into
a permanent partial one, which is worse in the specific sense that nobody is
paged for it. Draining stops the bleeding but removes capacity mid-incident and
the nodes still carry the change when they return.

### The part worth remembering

**Staging and rollback speed are answers to different questions.** Rollback
time is measured from the moment you know, so total damage is detection plus
decision plus rollback — and for a change that reaches everything in forty
seconds, the first two terms dominate and no rollback is fast enough. Staging
does not shorten any of those terms. It bounds the *number of nodes* that can
be affected before the first reading is taken. "Faster rollback" shortens an
outage; staging prevents a global one. Postmortems reach for the first because
it is the one that feels like going faster.

**The gate is a hypothesis test, and it has two error modes.** Almost everyone
designs for the false negative — the bad change that gets through — and then
sets a threshold so tight that good changes trip it. The second failure is the
one that actually destroys the safeguard, because it is resolved socially: an
exception for the urgent fix, then exceptions as the norm, and a control
everyone believes in and nobody passes through. Any rollout policy you propose
should be tested against a healthy change before it is tested against a bad one.

**Pick the signal that discriminates, not the signal you already alert on.**
Most teams have error-rate alarms and would have gated on them, and in this
incident that gate would have promoted through every stage watching a flat
line. The test for a candidate signal is not "is it important" but "does it
read differently on a broken node than a healthy one, within the time I am
willing to bake". A signal that only moves once the failure is total is a
signal that confirms the outage you already have.

**Bake time is detection latency, and it sets the floor on your rollout.**
Stages multiply it: four stages at a 60-second bake is four minutes to full
fleet, and that is the optimistic number, since a real gate needs a decision as
well as a reading. That cost is the actual reason staged rollouts get skipped,
and it is worth naming honestly rather than pretending the policy is free — a
security fix for an active attack is now four minutes from merge to protection,
and somebody has to be allowed to accept that risk deliberately rather than
route around the system to avoid it.

**The thing being deployed was configuration, not code.** It went out through a
path built for speed precisely because config "isn't a deploy". Anything that
changes what production does is a deploy, and the fast path around your
pipeline is where your next global outage comes from — feature flags, WAF
rules, DNS, routing tables, kill switches. The rollout discipline belongs to
the change, not to the artefact type.

</details>
