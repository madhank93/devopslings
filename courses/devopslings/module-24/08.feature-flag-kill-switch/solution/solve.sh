#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Flags are read from ff.flags on every request; any failure to read one
# gives its safe default. The flags that stopped changing a year ago become
# the behaviour they had, and their rows go.
set -euo pipefail
cat > /ha/app/routes/recommend.py <<'PY'
# GET /recommend — what to show a customer next.
import random

# What each flag reads as when ff.flags has no row for it or cannot be reached.
SAFE = {"new_ranker": False}


def flag(db, name):
    try:
        with db() as c:
            row = c.execute("SELECT enabled FROM ff.flags WHERE name = %s", (name,)).fetchone()
    except Exception:
        return SAFE.get(name, False)
    return row[0] if row else SAFE.get(name, False)


def new_ranker():
    if random.random() < 0.3:
        raise TimeoutError("ranking service did not answer in 800 ms")
    return ["socks", "boots", "scarf"]


def old_ranker():
    return ["socks", "hat", "gloves"]


def handle(db):
    if flag(db, "new_ranker"):
        path = "new"
        try:
            items = new_ranker()
        except TimeoutError as e:
            return 500, f"recommend failed: {e}", {"X-Path": path}
    else:
        path, items = "old", old_ranker()
    return 200, {"items": items, "theme": "dark"}, {"X-Path": path}
PY
psql -qX -c "DELETE FROM ff.flags WHERE name IN ('dark_mode', 'holiday_banner', 'legacy_tax')"
psql -qX -c "UPDATE ff.flags SET enabled = false, changed_at = now() WHERE name = 'new_ranker'"
sleep 2
