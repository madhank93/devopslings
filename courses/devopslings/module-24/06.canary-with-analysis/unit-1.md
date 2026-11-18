---
title: "Canary with automated analysis"
---

## The situation

`GET /checkout` is served by whichever build `/ha/deploy/<node>` names, from
`/ha/deploy/builds/`. web1 runs v1. web2 runs v2, and v2 passed CI:

```
$ /ha/sre/ci-smoke web2
PASS: 5/5
```

It is also slower, and nobody has noticed, because the load balancer still
splits traffic evenly and nobody compared the two. Half of all customers are
on an untested build. That is a deploy, not a canary.

A canary is two things: a **small share of real traffic** on the new build,
and an **automated comparison** with the old one that decides whether it goes
further.

`/ha/sre/drive-traffic SECONDS` sends customers through `www` and prints one
HAProxy httplog line per request, as in lesson 1: `app/web1` or `app/web2` in
the fourth field, the timers in the fifth, the status in the sixth.

## Your objectives

1. Make web2 a canary: about one request in ten.
2. Write `/ha/sre/canary-analysis LOG`. It compares web2 with web1 in that
   log and exits 0 to promote or 1 to reject. When it rejects, it prints a line
   `reject: errors` or `reject: latency`, for the metric that moved.

## What you're being graded on

The grader deploys three builds to web2 in turn, drives 15 seconds of
traffic for each, and runs your analysis on the log:

- web2 must answer between 4% and 20% of requests;
- a good build (as good as v1, including v1's occasional failure) is promoted;
- a build that fails 6% of checkouts is rejected with `reject: errors`;
- a build that is slow on a quarter of requests, and never fails, is
  rejected with `reject: latency`.

## Try it yourself

```
/ha/sre/drive-traffic 15 > /ha/sre/sample.log
awk '{print $4}' /ha/sre/sample.log | sort | uniq -c
/ha/sre/canary-analysis /ha/sre/sample.log; echo "exit $?"
```

<details>
<summary>Hint 1 — compare with the baseline</summary>

v1 fails a checkout now and then, when the payment provider times out. A
canary that rejects on "any error at all" rejects every build. The question
an analysis answers is "is the canary worse than what is running now?", so
every number is a comparison with the baseline, measured over the same
minutes with the same customers.

</details>

<details>
<summary>Hint 2 — rates, and the tail</summary>

The canary sees a tenth of the requests, so it sees a tenth of the errors
even when it is just as good. Compare error *rates*. For latency, an average
moves little when a quarter of requests get slow; p95 or p99 is where a
regression shows.

</details>

<details>
<summary>Solution</summary>

In `/ha/haproxy.cfg`:

```
    server web1 172.29.22.21:8080 check inter 1s fall 2 rise 2 weight 90
    server web2 172.29.22.22:8080 check inter 1s fall 2 rise 2 weight 10
```

```python
#!/usr/bin/env python3
import sys
from collections import defaultdict

seen = defaultdict(list)
for line in open(sys.argv[1]):
    f = line.split()
    seen[f[3].split("/")[-1]].append((int(f[5]), int(f[4].split("/")[4])))
base, canary = seen["web1"], seen["web2"]
if len(canary) < 50 or len(base) < 50:
    sys.exit("inconclusive")

def error_rate(xs): return sum(s >= 500 for s, _ in xs) / len(xs)
def p95(xs):
    t = sorted(ms for _, ms in xs)
    return t[int(len(t) * 0.95) - 1]

if error_rate(canary) > 2 * error_rate(base) + 0.01:
    print("reject: errors"); sys.exit(1)
if p95(canary) > 2 * p95(base) + 50:
    print("reject: latency"); sys.exit(1)
print("promote")
```

### The margins

`2 * baseline + 0.01` and `2 * baseline + 50 ms` are tolerances for noise. With
a few hundred canary requests, a build that is exactly as good as v1 still
shows a slightly different error rate on any given run. Too tight and good
builds get rejected until people stop trusting the analysis; too loose and a
real regression gets through. Tools like Kayenta use statistical tests for
the same decision; the shape is the same.

### Why "the metric that moved" matters

A rejection is the start of an investigation. "Rejected: errors" sends
someone to the error logs; "rejected: latency" sends them to a profiler.
Naming the wrong one costs the time it takes to find out.

### What CI cannot see

CI ran five requests against an idle node. The slow path is a quarter of
requests, under load, with real traffic. Only production traffic shows that,
which is why the canary exists: the smallest exposure that is still real.

</details>
