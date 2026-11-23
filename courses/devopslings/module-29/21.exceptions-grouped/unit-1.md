---
title: "Ten thousand errors, and how many bugs?"
---

## The situation

A minute ago checkout recorded about ten thousand exceptions. Each one is an
event on the span of the request that failed, and all of them are in Tempo:

```
curl -s -G http://tempo:3200/api/search \
  --data-urlencode 'q={resource.service.name="checkout" && status=error}' \
  --data-urlencode limit=2 | jq
```

The error-rate panel went vertical and the on-call has declared an outage of
everything. The first thing anyone tried was grouping by message, and every
group had one event in it:

```
payment provider did not answer for order ord-4417203 (412.07 EUR) after 2.0s
KeyError: 'sku-48120'
invalid literal for int() with base 10: 'two61'
```

Tempo stores spans; it does not group errors into issues the way Sentry or
an APM vendor's error view does. You have its API, `jq` and Python.

## What an exception event carries

`span.record_exception(e)` adds an event named `exception` to the span, with
three attributes from the OpenTelemetry semantic conventions:

| Attribute | Example |
|---|---|
| `exception.type` | `KeyError` |
| `exception.message` | `'sku-48120'` |
| `exception.stacktrace` | the whole traceback, as text |

A **bug** is a place in the code that raises a particular exception. That is
what error trackers group on: the exception type plus the frame where it was
raised, which in a Python traceback is the last `File ..., in <function>`
line, just above the message. Two things that look like grouping keys are
not:

- **The message** carries IDs, SKUs and amounts. Every event is unique.
- **The whole stack trace** ends in the message too, and the same raising
  line reached from two different callers has two different traces.

And the type alone merges different bugs that happen to raise the same
exception class.

To read the events, fetch a trace by ID (`/api/traces/<id>`) and look at
each span's `events`. A search returns 20 traces unless you pass a bigger
`limit`, and the start and end of the window as epoch seconds.

## Your objectives

In `/obs/answers/issues.txt`, one line per distinct bug, the one with the
most events first:

```
<exception.type> | <function the exception was raised in> | <number of events>
```

## What you're being graded on

- the right number of distinct bugs, each named by its type and raising
  function
- each count within 3% of the events Tempo holds for that bug
- the lines ranked by count, most first

<details>
<summary>Hint 1 — getting every event</summary>

Search for checkout's error spans over the last hour with a `limit` well
above ten thousand, then fetch each trace. A thread pool makes ten thousand
local fetches take seconds, not minutes.

</details>

<details>
<summary>Hint 2 — the key</summary>

`re.findall(r'File "[^"]+", line \d+, in (\S+)', stacktrace)[-1]` is the
function the exception was raised in. Count `(exception.type, that)`.

</details>

<details>
<summary>Solution</summary>

```python
import collections, json, re, time, urllib.parse, urllib.request
from concurrent.futures import ThreadPoolExecutor

def get(path, **params):
    with urllib.request.urlopen(f"http://tempo:3200{path}?{urllib.parse.urlencode(params)}") as r:
        return json.load(r)

now = int(time.time())
found = get("/api/search", q='{resource.service.name="checkout" && status=error}',
            start=now - 3600, end=now, limit=100000)["traces"]

def events(tid):
    t = get(f"/api/traces/{tid}")
    return [{a["key"]: a["value"].get("stringValue") for a in e["attributes"]}
            for b in t["batches"] for ss in b["scopeSpans"] for s in ss["spans"]
            for e in s.get("events", []) if e["name"] == "exception"]

bugs = collections.Counter()
with ThreadPoolExecutor(16) as ex:
    for evs in ex.map(events, [t["traceID"] for t in found]):
        for a in evs:
            top = re.findall(r'File "[^"]+", line \d+, in (\S+)', a["exception.stacktrace"])[-1]
            bugs[(a["exception.type"], top)] += 1

for (t, fn), n in bugs.most_common():
    print(f"{t} | {fn} | {n}")
```

Five bugs: two `KeyError`s (a price lookup for a SKU that is not in the
catalogue, and a cart that is not in the cache), two `TimeoutError`s (the
payment provider and the inventory lock), and one `ValueError` from parsing
a quantity. Ten thousand events, five tickets, and an order to work them in.

### The ways this goes wrong

- **Grouping by message, or by the whole stack trace.** Thousands of groups.
- **Grouping by type.** Three groups, and the payment timeout hides the
  inventory timeout inside it.
- **Grouping by the outermost frame.** Every event goes through the request
  handler; that frame says which endpoint, not which bug. `lookup_price` is
  called from two endpoints and is still one bug.
- **Counting from the default search.** Twenty traces, and a ranking of
  whatever came back first.

</details>
