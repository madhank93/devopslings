---
title: "The server answers in 80ms, and customers wait four seconds"
---

## The situation

Support has a dozen tickets saying the checkout page takes about four
seconds. checkout's dashboard says p99 80ms, from its `SERVER` spans, and
the team has been replying that the server is fast. Both are true.

A frontend engineer turned on browser timing collection for a day and
sampled 2,000 checkout page views into `/obs/rum/` (read
`/obs/rum/README` first):

- `navigation.csv`: the browser's Navigation Timing for each page view
- `resources.csv`: Resource Timing for each script the page loads
- `server.csv`: the server span's duration for the same requests, joined
  by trace ID

This is a design question with numbers in it. Nothing is broken in the
sandbox; the answer is a diagnosis and a plan.

## What a server span measures

A server span starts when the request reaches the server and ends when the
response leaves it. Everything before and after happens somewhere the
server cannot see:

```
0 ─ DNS ─ TCP ─ TLS ─┬─ request ─ [server span] ─ first byte ─ download ─┬─ parse, scripts, render ─ load
                     requestStart                responseStart          responseEnd             loadEventEnd
```

**Navigation Timing** gives those boundaries as timestamps, in ms from the
start of the navigation:

| Phase | From | To |
|---|---|---|
| dns | `domainLookupStart` | `domainLookupEnd` |
| tcp | `connectStart` | `secureConnectionStart` |
| tls | `secureConnectionStart` | `connectEnd` |
| waiting | `requestStart` | `responseStart` (the server's time plus a round trip) |
| download | `responseStart` | `responseEnd` |
| render | `responseEnd` | `loadEventEnd` |

**Resource Timing** does the same for each file the page fetches.
`renderBlockingStatus` says whether the browser had to stop and wait for
it. A long fetch that nothing waits for costs the user nothing.

Measured in real users' browsers, this is **real user monitoring** (RUM).
It is the only place the four seconds exist as data.

Use percentiles, not averages: compute each phase per page view, then take
the 75th percentile, which is what Core Web Vitals use.

## Your objectives

Fill in `/obs/answers/rum.txt`:

- `where`: the phase most of the page load is spent in, and `where_ms`, its p75
- `culprit`: the single thing in that phase that costs the most, by its URL
- `server_ms`: the p75 of the server's own time
- `rum_sees`: what the browser's timings measure that a server span cannot
- `instrument`: what to add, and where, so production shows this on every
  page view instead of a one-day sample

## What you're being graded on

- `where` is the phase with the largest p75, and `where_ms` is within 10%
- `culprit` is the resource that actually holds the page up, not merely the
  longest fetch in the file
- `server_ms` is within 20% of server.csv's p75
- `rum_sees` covers the network, what the browser does with the response,
  and third-party resources
- `instrument` is something that runs in the browser

<details>
<summary>Hint 1 — the phases</summary>

In Python: `csv.DictReader`, subtract the two columns for each phase per
row, sort, and take the value three quarters of the way up. Six numbers;
one of them is most of the total.

</details>

<details>
<summary>Hint 2 — which script</summary>

Sort the scripts by p75 duration, then look at two more columns for each:
`renderBlockingStatus`, and `startTime` compared with the view's
`loadEventEnd`.

</details>

<details>
<summary>Solution</summary>

```python
import csv, math

def p75(xs):
    xs = sorted(xs)
    return xs[math.ceil(0.75 * len(xs)) - 1]

nav = list(csv.DictReader(open("/obs/rum/navigation.csv")))
for name, a, b in [("dns", "domainLookupStart", "domainLookupEnd"),
                   ("tcp", "connectStart", "secureConnectionStart"),
                   ("tls", "secureConnectionStart", "connectEnd"),
                   ("waiting", "requestStart", "responseStart"),
                   ("download", "responseStart", "responseEnd"),
                   ("render", "responseEnd", "loadEventEnd")]:
    print(name, round(p75([float(r[b]) - float(r[a]) for r in nav])))
```

Render is around three seconds of the four. Everything up to the last byte
of HTML, server included, is a few hundred milliseconds, most of it network
on mobile. The server's own p75 is about 50ms.

In `resources.csv`, the longest fetch is the RUM vendor's beacon, and it
starts after `loadEventEnd`: nobody waits for it. Of the two render-blocking
scripts, a third-party one in the page's `<head>` takes two seconds or more
on every view, and the app bundle cannot start until it finishes. That is
the culprit. The fix belongs to whoever put a synchronous third-party tag
in the head: load it `async`, self-host it, or give it a timeout.

```
where: render
where_ms: <your p75>
culprit: <the blocking third-party script's URL>
server_ms: <server.csv's p75>
rum_sees: network time (DNS, TCP and TLS, round trips), the browser parsing and running JavaScript and rendering, and third-party scripts the page waits for
instrument: RUM in the browser: the OpenTelemetry web SDK or web-vitals, reporting Navigation and Resource Timing and LCP/INP from every page view, carrying the HTML request's traceparent so a slow view links to its server trace
```

### The ways this goes wrong

- **"The server is fast."** True, and the reason the page is slow is not
  in any number the server produces.
- **Averages.** A third of the views are fast desktop loads; the mean hides
  how slow the mobile tail is.
- **The longest resource.** Duration is how long a fetch took, not whether
  the page waited for it. The beacon is the longest and costs nothing.
- **The app bundle.** It blocks rendering, and it is a fraction of the
  third-party script it waits behind.
- **More server spans.** Nothing on the server can see DNS, TLS, or a
  script in someone else's CDN.

</details>
