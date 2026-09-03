#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# There is no single right policy here. This one is a defensible set of
# choices: one node first so being wrong is cheap, cpu_p95 because it is the
# signal that actually moved, a bake long enough for the cost to appear under
# real traffic, and a threshold between healthy (41) and broken (97).
set -euo pipefail

cat > policy.env <<'ENV'
# The rollout policy. Replace every ? and keep the shell syntax valid —
# both the harness and the grader read this file with `.`.

# One node, then five, then a quarter, then the rest. The first stage is one
# machine because the only thing it has to be is survivable.
STAGES=1,5,25,100

# The signal that moved during the incident. The error rate did not.
SIGNAL=cpu_p95

# Healthy nodes read 41 and the bad rule drives them to 97. 80 leaves room for
# an ordinary busy afternoon without leaving room for this.
THRESHOLD=80

# The CPU cost only shows up after about thirty seconds of real traffic, so a
# shorter bake reads a node that has not been asked to do the expensive thing
# yet. 60 gives the signal twice the time it needs.
BAKE_SECONDS=60
ENV

cat > answers/rollout.md <<'MD'
# Rollout design

# One of: revert | freeze | drain
# What happens to the nodes that already have the change when a stage fails
# its gate.
abort-action: revert

# Why this signal and not the other one. Name what the other one would have
# done during this incident.
signal: cpu_p95 is the signal that separates the two changes — 41 healthy against 97 with the bad rule. http_5xx_per_10k was flat at 10 throughout, because the rule made requests expensive rather than wrong; nodes returned correct answers slowly until they saturated, and by then every node had the rule. Gating on errors would have watched a number that never moved and promoted through every stage.

# What this rollout costs. A change that used to be live in forty seconds now
# takes how long, and who pays for that?
cost: Four stages at a 60-second bake is about four minutes to full fleet instead of forty seconds, and that is the floor — a real gate also needs someone or something to decide, so the honest number is longer. The people who pay are whoever is waiting on an urgent rule: a security fix for an active attack is now four minutes from merge to protection. That is the trade, and it is worth taking, but it means the emergency path has to be a deliberate decision to accept the risk rather than an accident of nobody having built stages.

# "We should just roll back faster" was the first suggestion in the
# postmortem. Say why it is not a fix for this.
why-not-faster-rollback: Rollback time is measured from the moment you know, and this change reached every node in forty seconds — faster than anyone could know. Even an instant rollback leaves a global outage whose length is detection plus decision plus rollback, and the first two terms are the big ones. Staging attacks a different quantity: it bounds how much of the fleet can be affected before the signal is read at all, so the worst case stops being "everything for as long as it takes us" and becomes "one node for one bake period". Faster rollback shortens an outage; staging prevents a global one.
MD

echo "policy.env and answers/rollout.md written"
