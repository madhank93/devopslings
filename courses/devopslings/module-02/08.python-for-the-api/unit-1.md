---
title: "the report that has been missing 40% of the records all year"
---

## The situation

`fetch-records` pulls the billing export:

```
$ fetch-records
fetch-records: wrote 50 records
$ wc -l /srv/api/records.txt
50
```

There are 437 records. The script exits 0, writes a file, and reports a number —
and 50 is a perfectly plausible number if you do not already know the answer.

```
$ curl -s 'http://127.0.0.1:8099/records?page=1' | jq '{page, total, next_page, n: (.items|length)}'
{
  "page": 1,
  "total": 437,
  "next_page": 2,
  "n": 50
}
```

The API has been saying `"total": 437` and `"next_page": 2` in every response
since the day this was written.

## Your objective

Write every record exactly once, sorted, to `/srv/api/records.txt`.

- **The API paginates.** The response tells you how to continue.
- **Some requests fail with 503.** Pages 2 and 5 fail on their first attempt,
  and page 5 fails again on its second — one blind retry is not enough.
- **One request returns 429 with `Retry-After`.** The server counts requests
  arriving before that deadline, and the check requires that count to be zero.

## What you're being graded on

437 distinct ids, no duplicates, sorted, `REC-00001` through `REC-00437`, and
zero rate-limit violations recorded by the server.

<details>
<summary>Hint 1 — follow the pagination the response describes</summary>

Do not compute a page count from `total / per_page`. The response carries the
answer:

```python
page = 1
while page is not None:
    data = get_page(page)
    ids.extend(item["id"] for item in data["items"])
    page = data.get("next_page")
```

`next_page` is `null` on the final page, which ends the loop. Deriving the
count yourself means duplicating the server's pagination arithmetic in your
client, and being wrong the moment it changes.

Never loop `while True` without a bound. A cursor that stops advancing turns
into an infinite loop against someone else's API, which is a much worse
incident than a missing report.

</details>

<details>
<summary>Hint 2 — which failures are worth retrying</summary>

Not all of them, and the distinction matters:

| status | meaning | retry? |
|---|---|---|
| 429 | too fast, slow down | yes, after the stated wait |
| 503 / 502 / 504 | temporarily unavailable | yes, with backoff |
| 500 | server bug | maybe once; it is unlikely to differ |
| 400 / 404 / 422 | your request is wrong | **no** — it will be wrong again |
| 401 / 403 | not authorised | no, until credentials change |

```python
except urllib.error.HTTPError as e:
    if e.code in (429, 503):
        ...retry...
    else:
        raise
```

Retrying a 404 just makes the same mistake repeatedly and, at scale, is how a
client turns its own bug into an outage for the service it is calling.

Bound the attempts. `MAX_ATTEMPTS = 6` and then give up loudly beats retrying
forever and hanging silently.

</details>

<details>
<summary>Hint 3 — back off, and honour Retry-After when you get it</summary>

Two different situations:

**A 503 with no guidance.** Back off exponentially so a struggling server is not
hammered by a client that has decided to help:

```python
delay = 0.5 * (2 ** (attempt - 1))    # 0.5, 1, 2, 4 ...
```

**A 429 with `Retry-After`.** The server has told you exactly how long. Use its
number:

```python
delay = float(e.headers.get("Retry-After", "1"))
```

This is the part the check measures directly. Your own backoff schedule is a
guess about a window only the server knows the size of; when it tells you, the
guess is strictly worse than the answer.

In production you would also add jitter, so a hundred clients that were rate
limited together do not all return at the same instant. That is module 21's
`backoff-and-jitter`, and it is the same idea one step further on.

</details>

<details>
<summary>Solution</summary>

```python
#!/usr/bin/env python3
import json, time, urllib.error, urllib.request

BASE = "http://127.0.0.1:8099/records"
MAX_ATTEMPTS = 6

def get_page(page):
    for attempt in range(1, MAX_ATTEMPTS + 1):
        try:
            with urllib.request.urlopen(f"{BASE}?page={page}", timeout=10) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code == 429:
                delay = float(e.headers.get("Retry-After", "1"))
            elif e.code == 503:
                delay = 0.5 * (2 ** (attempt - 1))
            else:
                raise
            if attempt == MAX_ATTEMPTS:
                raise
            time.sleep(delay)
    raise RuntimeError(f"page {page}: exhausted retries")

ids, page = [], 1
while page is not None:
    data = get_page(page)
    ids.extend(item["id"] for item in data["items"])
    page = data.get("next_page")

ids = sorted(set(ids))
with open("/srv/api/records.txt", "w") as f:
    f.write("\n".join(ids) + "\n")
print(f"fetch-records: wrote {len(ids)} records")
```

### Why this is a lesson at all

This is the module's `deep` exercise and the place where shell stops being the
right answer. You *can* do this with `curl` and `jq` in a loop. Doing it
correctly — parsing `Retry-After`, tracking attempts per page, exponential
backoff, distinguishing retryable from permanent — is where the shell version
becomes longer and less readable than the Python one, which is exactly the
judgement the next exercise asks you to make.

Three things worth keeping:

1. **A successful exit says nothing about completeness.** The original wrote a
   file, printed a count and returned 0. Every signal available said success.
   Anything that fetches a collection should assert something about *how much*
   it got — a total from the API, a floor, a comparison with last run.

2. **The server is telling you things. Read them.** `total`, `next_page` and
   `Retry-After` were all in responses the client already had and threw away.
   A client that ignores the protocol re-implements it worse.

3. **Retry is a decision per status, not a blanket policy.** Retrying
   everything hammers a server over requests that can never succeed; retrying
   nothing loses data to a blip. And an unbounded retry is not resilience, it is
   a hang — which is `no-timeout-hangs` and `retry-storm` in module 21, from the
   client's side.

</details>
