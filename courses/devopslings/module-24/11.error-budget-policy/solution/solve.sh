#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The one consequence the team fully controls is its own deploys, so the
# policy stops features there, keeps fixes flowing, and lifts itself when
# the budget is positive again. The gate goes in the deploy tool itself.
set -euo pipefail
cat > /ha/answers/policy.txt <<'TXT'
applies_when: budget remaining (/ha/sre/budget) is at or below 0%
stops: checkout feature deploys; the sprint's feature work moves to reliability
continues: fixes, rollbacks, and security patches
decides: erin
unblocks: budget remaining back above 0%
TXT
python3 - <<'PY'
p = "/ha/sre/deploy"
s = open(p).read()
gate = '''
# Error budget policy (/ha/answers/policy.txt): no features while the budget is spent.
if [ "$kind" = feature ] && awk -v r="$(/ha/sre/budget --remaining)" 'BEGIN { exit !(r <= 0) }'; then
  echo "deploy: refused. Checkout's error budget is spent ($(/ha/sre/budget --remaining)% left)." >&2
  echo "        Features wait until it is back above 0%; exceptions: erin." >&2
  exit 1
fi
'''
marker = 'esac\n'
s = s.replace(marker, marker + gate, 1)
open(p, "w").write(s)
PY
