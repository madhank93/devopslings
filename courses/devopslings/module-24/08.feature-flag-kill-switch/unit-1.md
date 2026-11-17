---
title: "Feature flag as a kill switch"
---

## The situation

The new recommendation ranker went out two days ago behind a "flag", and it
is failing about a third of requests:

```
$ for i in $(seq 10); do curl -s -o /dev/null -w '%{http_code} ' http://www/recommend; done
200 500 200 200 500 200 200 500 200 200
```

The flag is a dictionary in the code (`/ha/app/routes/recommend.py`):

```python
FLAGS = {"new_ranker": True, "dark_mode": True, "holiday_banner": False}
```

Turning it off means editing the file, which is a deploy, with a deploy's
review and its risks, at the worst possible moment. Somebody created a table
for flags (`ff.flags`) and never wired it in:

```
      name      | enabled |  changed_at
----------------+---------+--------------
 new_ranker     | t       | 2 days ago
 dark_mode      | t       | 412 days ago
 holiday_banner | f       | 318 days ago
 legacy_tax     | f       | 700 days ago
```

`/ha/sre/flag-audit` is the quarterly flag review. It finds `flag(db,
"name")` calls in `/ha/app/routes` and compares them with the table.

## Your objectives

1. `flag(db, name)` reads `ff.flags`, so turning `new_ranker` off is an
   `UPDATE`, and it takes effect within seconds on both nodes.
2. When the flag store cannot be read, a flag falls back to a safe value
   rather than failing the request. For `new_ranker`, safe is off.
3. `/ha/sre/flag-audit` prints nothing, and customers see the same page
   they did before: dark theme, no holiday banner.

## What you're being graded on

- The grader sets `new_ranker` on in `ff.flags` and expects the new ranker
  within 10 seconds; then off, and expects every request on the old ranker
  within 5 seconds. It never touches the code.
- It renames `ff.flags` away: `/recommend` must still answer 200, on the old
  ranker.
- Its copy of the flag review must be clean, with the dark theme kept and no
  banner.

## Try it yourself

```
psql -c "UPDATE ff.flags SET enabled = false, changed_at = now() WHERE name = 'new_ranker'"
for i in $(seq 10); do curl -s -D - -o /dev/null http://www/recommend | grep -i x-path; done
/ha/sre/flag-audit
```

<details>
<summary>Hint 1 — when the flag is read</summary>

The app loads a route file again only when the file changes. Anything read
at import time, or kept in a dictionary that lives as long as the module,
is frozen until the next deploy. A kill switch has to be read on the
request it decides about, or from a cache that expires within a second or
two.

</details>

<details>
<summary>Hint 2 — the review</summary>

`dark_mode` has been on for every customer for over a year. It is not a
switch any more; it is the theme. Removing a flag means removing the branch
too, keeping the side that has been live. Delete the row and leave the
`flag(db, "dark_mode")` call, and the call reads a missing flag, and gets
"off".

</details>

<details>
<summary>Solution</summary>

```python
SAFE = {"new_ranker": False}

def flag(db, name):
    try:
        with db() as c:
            row = c.execute("SELECT enabled FROM ff.flags WHERE name = %s", (name,)).fetchone()
    except Exception:
        return SAFE.get(name, False)
    return row[0] if row else SAFE.get(name, False)

def handle(db):
    if flag(db, "new_ranker"):
        ...
    else:
        path, items = "old", old_ranker()
    return 200, {"items": items, "theme": "dark"}, {"X-Path": path}
```

```sql
DELETE FROM ff.flags WHERE name IN ('dark_mode', 'holiday_banner', 'legacy_tax');
```

### A query per request

One indexed lookup on a tiny table is cheap next to everything else the
request does. At scale, flag services keep the flags in memory and push
changes to every process within a second or so; what they never do is
cache for minutes. The property that matters is the time from "flip" to
"every process obeys", and it has to be shorter than the time a deploy
would take, or the flag has bought nothing.

### Failing safe

The flag store is a dependency of every request that consults it. When it
is down, each flag needs an answer that is safe without knowing anything:
for a kill switch that guards something new, that answer is "off". The
module-22 lesson on serving stale data is the same decision, made for a
different dependency.

### Why stale flags are debt

Every flag doubles the number of ways the code can run. A flag that has not
changed in a year is a branch nobody tests, kept alive by a row nobody
remembers, until someone flips it during an incident and gets a
year-old code path in production. Knight Capital (module 21) lost $440
million to a repurposed flag that woke up old code.

</details>
