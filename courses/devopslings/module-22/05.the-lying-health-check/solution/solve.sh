#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The check runs the query every request depends on. db() connects with a
# 2-second timeout, so a node that cannot reach Postgres fails the check
# rather than hanging it.
set -euo pipefail
cat > /ha/app/health.py <<'PY'
def check(db):
    try:
        with db() as conn:
            conn.execute("SELECT 1")
    except Exception as e:
        return False, f"database unreachable: {type(e).__name__}"
    return True, "database reachable"
PY
sleep 3
