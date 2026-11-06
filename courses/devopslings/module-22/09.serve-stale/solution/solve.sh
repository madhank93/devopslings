#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Every successful read refreshes a per-node copy. When the read fails, the
# copy is served with its age, and only a node with no copy at all fails.
set -euo pipefail
cat > /ha/app/routes/catalog.py <<'PY'
import time

last = None  # (body, fetched_at) from the last read that worked


def handle(db):
    global last
    try:
        with db() as conn:
            count, newest = conn.execute(
                "SELECT count(*), coalesce(max(id), 0) FROM orders"
            ).fetchone()
    except Exception:
        if last is None:
            return 503, "catalog unavailable"
        body, at = last
        return 200, body, {"X-Stale": int(time.time() - at)}
    last = ({"orders": count, "newest": newest}, time.time())
    return 200, last[0]
PY
sleep 2
