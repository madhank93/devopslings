#!/usr/bin/env bash
# Stage 4's check: the rubric over postmortem.md and runbook.md, then every
# runbook command run from the host against ha-stack, which must still be
# serving afterwards.
set -euo pipefail
. "$DEVOPSLINGS_ROOT/courses/devopslings/module-27/files/lib.sh"
. "$DEVOPSLINGS_ROOT/courses/devopslings/module-27/04.stage-4-write-it-up/files/common.sh"

for f in postmortem.md runbook.md; do
  if [ ! -s "$S/$f" ]; then
    echo "not yet: scratch/stage-4-write-it-up/$f is missing or empty."
    exit 1
  fi
done
if ! ops test -s /var/lib/capstone/events.log || ! ops test -s /var/lib/capstone/team.txt; then
  echo "not yet: events.log or team.txt is gone from devopslings-ha-ops. Start the lesson again."
  exit 1
fi

# ---- the rubric --------------------------------------------------------------
for f in postmortem.md runbook.md; do
  docker exec -i devopslings-ha-ops sh -c "cat > /tmp/stage-4-$f" < "$S/$f"
done
docker exec -i devopslings-ha-ops python3 - /tmp/stage-4-postmortem.md /tmp/stage-4-runbook.md \
  /var/lib/capstone/events.log /var/lib/capstone/team.txt < "$F/grade.py" || exit 1

# ---- the runbook's commands --------------------------------------------------
# sh, bash and shell blocks run whole; console blocks run their "$ " lines.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
awk -v d="$work" '
  !open && /^[ \t]*```/ {
    open = 1; ind = $0; sub(/```.*/, "", ind)
    lang = $0; sub(/^[ \t]*```[ \t]*/, "", lang); sub(/[ \t].*/, "", lang); lang = tolower(lang)
    run = (lang ~ /^(sh|bash|shell|console)$/); con = (lang == "console"); more = 0
    if (run) f = sprintf("%s/%03d.sh", d, ++n)
    next
  }
  open && /^[ \t]*```[ \t]*$/ { open = 0; if (run) close(f); next }
  open && run {
    l = $0; if (index(l, ind) == 1) l = substr(l, length(ind) + 1)
    if (con) {
      if (more) { print l > f }
      else if (l ~ /^\$ /) { print substr(l, 3) > f }
      else next
      more = (l ~ /\\$/)
    } else print l > f
  }
' "$S/runbook.md"

count=0
for b in "$work"/*.sh; do
  [ -e "$b" ] || continue
  count=$((count + $(grep -cvE '^[[:space:]]*(#|$)' "$b" || true)))
done
if [ "$count" -lt 3 ]; then
  echo "not yet: runbook.md has ${count} command(s) in sh or console blocks. Everything in those"
  echo "         blocks is run against the sandbox, and a runbook with nothing to run has not been"
  echo "         tried: who knows if its commands work at 3 a.m.?"
  exit 1
fi

# Production as the earlier stages left it, so a step that broke it on an
# earlier check is not blamed on this runbook.
ensure_prod
problem=$(prod_problem 60)
if [ -n "$problem" ]; then
  echo "not yet: production is not serving before the runbook runs: ${problem}."
  echo "         Reset the lesson; the check could not put it back."
  exit 1
fi

for b in "$work"/*.sh; do
  [ -e "$b" ] || continue
  # Its own process group, so a timeout also stops what the block started.
  set -m
  (cd "$S" && exec bash -e "$b") >"$b.out" 2>&1 </dev/null &
  pid=$!
  set +m
  (sleep 60 && kill -- "-$pid" 2>/dev/null) &
  timer=$!
  rc=0
  wait "$pid" || rc=$?
  kill "$timer" 2>/dev/null || true
  [ "$rc" -eq 0 ] && continue
  echo "not yet: this block in runbook.md $([ "$rc" -ge 128 ] && echo "was still running after 60 seconds" || echo "exited $rc"):"
  sed 's/^/           /' "$b"
  echo "         its last output:"
  tail -5 "$b.out" | sed 's/^/           /'
  if grep -qE '<[A-Za-z_-]+>|YOUR_|REPLACE' "$b"; then
    echo "         It has a placeholder in it. Whoever runs it is paged and tired: write the"
    echo "         command that finds the value, not a blank for them to fill."
  elif [ "$rc" -ge 128 ]; then
    echo "         A command that follows or watches forever never hands the shell back; give it"
    echo "         a limit, like --tail or --since, or a loop that gives up."
  else
    echo "         Every command in an sh or console block is run, from scratch/stage-4-write-it-up,"
    echo "         against ha-stack alone. A runbook command that fails in a quiet sandbox fails"
    echo "         in the incident too."
  fi
  exit 1
done

problem=$(prod_problem 45)
if [ -n "$problem" ]; then
  echo "not yet: after the runbook's commands ran, ${problem}."
  echo "         A runbook step may restart or fail over, but the runbook as a whole has to leave"
  echo "         production serving: a step that takes something away needs the step that puts"
  echo "         it back. The check has restored production; fix the runbook and check again."
  ensure_prod
  exit 1
fi

echo "runbook: ${count} commands ran against ha-stack, and production still serves"
echo
echo "PASS: a timeline from the log, impact against the SLO, conditions instead of culprits,"
echo "actions somebody owns, and a runbook that works when it is run."
