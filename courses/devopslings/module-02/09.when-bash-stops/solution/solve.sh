#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# There is no command to run here. The deliverable is a written verdict, and
# the grader checks the pairing of decision and reason, plus a stated cost for
# each — because a choice with no downside is not an engineering decision.
set -euo pipefail

install -d /root/answers
cat > /root/answers/verdict.md <<'ANS'
case-1: verdict=shell because=composition
cost-1: No types and no test harness, so a change to the S3 path or the date
        arithmetic is only checked by running it against real storage.

case-2: verdict=program because=datastructures
cost-2: A build step, a language runtime on the finance host, and a smaller
        pool of people who can read it during month-end close.

case-3: verdict=program because=testing
cost-3: More ceremony for 55 lines of work, and a deploy tool that now needs
        deploying itself — plus a runtime present on every app host.

case-4: verdict=shell because=dependencies
cost-4: Health-check logic that cannot grow much before it becomes unreadable,
        with no way to unit test it inside an image this small.

closest-call: Case 3. Fifty-five lines is small enough that rewriting it looks
like over-engineering, and the same argument would leave case 1 alone. What
separates them is blast radius: rotate.sh copies files, deploy.sh runs as root
and deletes directories on every host, and prune() cannot be exercised anywhere
except a real machine. Size is not the axis; what happens when it is wrong is.
ANS
