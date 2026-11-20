#!/usr/bin/env bash
# Stage 4's init: production serving on ha-stack, events.log holding a
# finished stage 2 and stage 3, and the write-up's templates. A postmortem or
# runbook already in scratch is the student's and is kept.
set -euo pipefail
. "$DEVOPSLINGS_ROOT/courses/devopslings/module-27/files/lib.sh"
. "$DEVOPSLINGS_ROOT/courses/devopslings/module-27/04.stage-4-write-it-up/files/common.sh"

mkdir -p "$S"
ensure_prod
problem=$(prod_problem 60)
if [ -n "$problem" ]; then
  echo "production did not come up on ha-stack: ${problem}. Reset the lesson."
  exit 1
fi

docker exec -i devopslings-ha-ops python3 - < "$F/events.py"
ops cat /var/lib/capstone/events.log > "$S/events.log"

cat > "$S/team.txt" <<'TXT'
priya   platform lead; owns the pipeline, the registry and the deploy
marco   SRE; owns the load balancers, alerting and on-call
dana    engineering manager for checkout
sam     engineer on checkout
TXT
docker exec -i devopslings-ha-ops sh -c 'cat > /var/lib/capstone/team.txt' < "$S/team.txt"

[ -e "$S/postmortem.md" ] || cat > "$S/postmortem.md" <<'MD'
# Postmortem: checkout

## Summary

## Impact

## Timeline

- YYYY-MM-DD HH:MM UTC  what happened

## Contributing factors

- a condition in the system

## Action items

- owner | what changes | YYYY-MM-DD
MD

[ -e "$S/runbook.md" ] || cat > "$S/runbook.md" <<'MD'
# Runbook: checkout

## Roles

## Severity

## When www is failing

```sh
docker exec devopslings-ha-ops curl -s -o /dev/null -w '%{http_code}\n' http://www/
```
MD

echo "scenario ready: production is serving, and the incidents are over. Write them up."
echo
echo "  what was recorded:  scratch/stage-4-write-it-up/events.log"
echo "                      (a copy of /var/lib/capstone/events.log in devopslings-ha-ops)"
echo "  who is on the team: scratch/stage-4-write-it-up/team.txt"
echo "  your write-up:      scratch/stage-4-write-it-up/postmortem.md and runbook.md"
echo
cat "$S/events.log"
