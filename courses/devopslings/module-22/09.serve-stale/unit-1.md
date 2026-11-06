---
title: "Serve stale: degrade instead of 500"
---

## The situation

`/catalog` shows how many orders the shop has and the newest one. It
queries pg1 on every request. The page is a summary, so an answer a minute
old is still useful to whoever is reading it.

Pause pg1 and request the page. Each request waits out the two-second
connect timeout and then fails with a 500. web1 and web2 both fail, so
HAProxy has nowhere else to send the request. A database hiccup takes the
whole page down with it, and every request during the hiccup counts
against the error budget.

## Your objectives

1. With the database up, `/catalog` answers 200 with the current data and
   no stale label.
2. With the database down, `/catalog` still answers 200 with the last
   answer it got from the database. The response carries
   `X-Stale: <age in whole seconds>`.
3. When the database comes back, the next answers are fresh again, and the
   label goes away.

The route is `/ha/app/routes/catalog.py`. `handle(db)` may return
`(status, body, {headers})`. A saved change applies to the next request.
Module-level variables persist between requests on the same node.

## What you're being graded on

The grader places an order and checks that `/catalog` shows it, with no
`X-Stale` header. Then it pauses pg1 and makes eight requests through www.
Every request must succeed, show that same newest order and carry a numeric
`X-Stale`. It resumes pg1, places another order, and expects four fresh
answers in a row within ten seconds.

## Try it yourself

```
curl -si http://www/catalog
node pause pg1
time curl -si http://www/catalog | head -1
node resume pg1
```

<details>
<summary>Hint 1 — what to keep</summary>

Keep a copy of the last answer that came from the database, and the time it
came. A module-level variable holds it between requests. web1 and web2 each
hold their own copy, and both are refreshed by the grader's fresh requests
before the database goes away.

</details>

<details>
<summary>Hint 2 — when to use it</summary>

Use the copy only when the query fails. Catch the exception, and if you have
a copy, return it with its age in seconds. Every successful query replaces
the copy. A cache that answers even when the database is up would hide new
orders, and the grader checks for that.

A node with no copy at all has nothing true to say, and should fail
honestly with a 503.

</details>

<details>
<summary>Solution</summary>

```python
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
```

### Spending the budget slowly

An error budget counts failed requests. A dependency that is down for a
minute costs one minute of requests if every page needs it. With this
change it costs nothing for this page. The outage is still real and the
data is still a minute old, but the page tells the client so. A client that
cannot use old data can see the header and refuse it.

Every request still waits for the connect timeout before the fallback is
served. A real service bounds that wait, or stops calling the database for
a while after a failure (a circuit breaker). Otherwise a slow database ties
up workers even though no request fails.

Serving stale data has to be decided per page. A catalog count can be a
minute old. A bank balance or a stock level used to accept an order should
not be served stale, because the client would act on a number that is no
longer true.

</details>
