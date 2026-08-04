---
title: "p99 spikes every few seconds and the CPU graph says 40%"
---

## The situation

`pricing-api` does about 15 ms of arithmetic per request. Its p99 is 92 ms.

```
$ sort -n /srv/pricing/latency.txt | awk '{a[NR]=$1} END {print "p50", a[int(NR*0.5)], "p99", a[int(NR*0.99)]}'
p50 15.4 p99 92.1
```

The median is exactly what the work costs. The tail is six times that. And the
box is not busy:

```
$ uptime
 03:14:02 up 2 days,  load average: 0.41, 0.38, 0.35
```

Idle cores. No I/O — the process only touches memory. No locks, no network, no
dependency. `top` shows the process using a fraction of one core. Every
dashboard says there is capacity to spare, and one request in a hundred takes
92 ms to do 15 ms of work.

## Your objectives

| file | answer |
|---|---|
| `/root/answers/cause` | one of `throttled`, `starved`, `blocked`, `slowcode` |

Then get p99 under **40 ms**, sustained.

`pricing-api` must keep a CPU limit — removing the bound is not the fix. The
loop must stay as it is; do not make the work cheaper.

## What you're being graded on

The named cause, then 20 seconds of fresh samples with p99 under 40 ms, and a
CPU limit still in place.

<details>
<summary>Hint 1 — a process can be runnable and not running</summary>

The states people usually reach for do not fit:

- **blocked** — a blocked process burns no CPU and sits in `S` or `D`. This one
  is on-CPU for its full 15 ms of work, then stops.
- **starved** — starvation means losing a race for a busy CPU. The box is idle;
  there is no race.
- **slowcode** — the loop is unchanged, and its p50 is exactly the 15 ms it
  should be. If the work had got more expensive, the median would have moved.

That leaves a fourth state, which `top` has no column for: **runnable, and
deliberately not scheduled.** The kernel has decided this cgroup has used its
allowance and will not run it again until the allowance refills.

</details>

<details>
<summary>Hint 2 — the counter that says so</summary>

Utilisation cannot show this, because averaged over a second the cgroup really
is using its share. The stall happens *inside* the averaging window.

The cgroup counts it directly:

```
$ cat /sys/fs/cgroup/system.slice/pricing-api.service/cpu.stat
usage_usec 4182233
user_usec 4180011
system_usec 2222
nr_periods 812
nr_throttled 597
throttled_usec 38221004
```

`nr_throttled 597` out of `nr_periods 812`. This cgroup was suspended in 73% of
all scheduling periods, and has spent 38 seconds runnable-but-stopped.

Those two numbers are the entire diagnosis, and nothing in `top`, `uptime`,
`vmstat` or a CPU utilisation graph contains them. If you take one thing from
this module, take the habit of reading `cpu.stat` for any workload with an
unexplained tail.

</details>

<details>
<summary>Hint 3 — the arithmetic of quota and period</summary>

```
$ systemctl show pricing-api -p CPUQuotaPerSecUSec -p CPUQuotaPeriodUSec
CPUQuotaPerSecUSec=200ms
CPUQuotaPeriodUSec=100ms
```

`CPUQuota=20%` with the default 100 ms period means: **20 ms of CPU per 100 ms
window.**

A request needs 15 ms. So:

- a request starting 0-5 ms into a period finishes inside the budget → ~15 ms
- a request starting later runs until the budget is gone, is suspended, and
  resumes at the start of the next period → **up to 80 ms of doing nothing**

That is the p50/p99 split exactly. Nothing is contended, nothing is slow — the
tail is the wait for a budget to refill.

Two levers, and they do different things:

- **raise the quota** — a bigger budget per period, so the work fits
- **shorten the period** (`CPUQuotaPeriodSec=`) — the same *share*, handed out
  in smaller pieces, so the worst-case wait shrinks from 80 ms toward the
  period length

The second is the one people miss, and it is often the better fix: it improves
the tail without giving the service more total CPU.

</details>

<details>
<summary>Solution</summary>

```
$ install -d /etc/systemd/system/pricing-api.service.d
$ cat > /etc/systemd/system/pricing-api.service.d/cpu.conf <<'CONF'
[Service]
CPUQuota=180%
CPUQuotaPeriodSec=20ms
CONF
$ systemctl daemon-reload && systemctl restart pricing-api
```

```
$ sort -n /srv/pricing/latency.txt | awk '{a[NR]=$1} END {print "p99", a[int(NR*0.99)]}'
p99 17.8
```

The limit is still there. It is now a limit the workload can run inside.

### Why this is a lesson at all

This is the single most common invisible latency cause in containerised
systems, and it is invisible for a specific and instructive reason: **every
tool people check reports an average over a window longer than the stall.**

The cgroup uses 20% of a core, averaged over a second. That is true. It is also
true that it spent 80 ms of most seconds suspended while runnable. Both
statements describe the same reality; only one of them explains the p99.

Three things worth keeping:

1. **Utilisation cannot show a stall shorter than its averaging window.** This
   is not a flaw in CPU graphs, it is arithmetic. Any question about tails needs
   a measurement of tails — which is what `nr_throttled`, `throttled_usec` and
   a latency histogram are for. Module 20 makes this argument in general; this
   is the concrete case.

2. **A limit that fires is not automatically wrong.** The instinct — throttling
   is hurting me, remove the throttle — hands the service the whole machine and
   makes its worst behaviour everyone else's problem. The limit is the thing
   that keeps a spike local. The fix is to set one the workload can work inside,
   which requires knowing what the workload actually needs. Same argument as
   `oom-killed` in module 01, one resource over.

3. **Quota and period are separate knobs and people only ever touch one.**
   Doubling the quota doubles the cost. Halving the period costs nothing and
   halves the worst-case wait. For latency-sensitive work with bursty CPU, the
   period is usually the better lever, and almost nobody reaches for it.

If you work with Kubernetes, this is exactly what a CPU *limit* does — the same
CFS quota, the same 100 ms period, the same throttling. It is the reason
experienced operators set CPU requests and are careful about CPU limits, and it
is worth having felt once rather than only read about.

</details>
