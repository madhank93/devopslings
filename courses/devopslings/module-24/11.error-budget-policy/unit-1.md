---
title: "Error budget policy"
---

## The situation

Checkout's SLO is 99.5% of requests good over 28 days. On day 9 and 10 an
incident spent most of the budget, and by day 14 it is 18% overspent
(`/ha/sre/budget`). In those same days the team shipped four more features
(`/ha/sre/deploys.log`). Nobody did anything wrong by the rules, because
there were no rules: an SLO with no policy is a number on a dashboard.

The policy has to be the checkout team's own. They wrote it, they own the
consequences, and they can only promise what they control
(`/ha/sre/team.txt`): their deploys, their backlog, their on-call, their
flags. Not the company release calendar, not other teams' deploys.

## Your objectives

1. Write the policy in `/ha/answers/policy.txt`: when it applies, what
   stops, what continues, who grants exceptions, and what ends it.
2. Make its consequence real: `/ha/sre/deploy` is the team's deploy tool,
   and every checkout deploy goes through it.

## What you're being graded on

- the decider is one named person on the team;
- what stops is something the team itself can stop;
- `applies_when` and `unblocks` are conditions with a number, as
  `/ha/sre/budget` reports it;
- with the budget spent, a feature deploy through `/ha/sre/deploy` does not
  go out, and a fix does;
- once the budget is back past your `unblocks` condition, features go out
  again without anyone editing anything.

## Try it yourself

`/ha/sre/budget --remaining` prints the number your gate needs.

<details>
<summary>Hint 1 — enforceable by whom</summary>

"All deploys freeze company-wide" is the policy people write first, and the
checkout team cannot carry it out: kai owns the calendar, other teams own
their deploys. "The VP decides exceptions" hands the policy to someone who
did not write it and is not in the room. A consequence is enforceable when
the people who wrote it can make it happen by themselves, today.

</details>

<details>
<summary>Hint 2 — the way out</summary>

The budget recovers when things stop breaking. Freezing everything also
freezes the fixes that would stop it breaking, and a freeze someone must
remember to lift lasts until someone remembers. The gate should read the
budget each time, and stop only what the policy says stops.

</details>

<details>
<summary>Solution</summary>

```
applies_when: budget remaining (/ha/sre/budget) is at or below 0%
stops: checkout feature deploys; the sprint's feature work moves to reliability
continues: fixes, rollbacks, and security patches
decides: erin
unblocks: budget remaining back above 0%
```

And in `/ha/sre/deploy`, after the `kind` is checked:

```bash
# Error budget policy (/ha/answers/policy.txt): no features while the budget is spent.
if [ "$kind" = feature ] && awk -v r="$(/ha/sre/budget --remaining)" 'BEGIN { exit !(r <= 0) }'; then
  echo "deploy: refused. Checkout's error budget is spent ($(/ha/sre/budget --remaining)% left)." >&2
  echo "        Features wait until it is back above 0%; exceptions: erin." >&2
  exit 1
fi
```

### Why the deploy tool

The team already had an SLO, a dashboard and good intentions, and shipped
four features into a spent budget. A written policy changes nothing until
the moment of the decision, and the moment of the decision is the deploy.
Putting the check there means nobody has to remember the policy; they meet
it.

### Why erin, and why one person

Exceptions will be asked for: a contractual launch date, a fix that is
labelled a feature. One named person on the team decides them, quickly. A
committee decides slowly and inconsistently; a VP decides without the
context, and while they are in meetings the team chooses between waiting
and ignoring the policy. Escalation above the team belongs in the policy
too, for disputes, but it is not who runs it day to day.

### What it does not say

Nothing about other teams, hiring, or the release calendar. If the outage
came from a dependency, the team's lever is to raise it with that team, not
to freeze them.

</details>
