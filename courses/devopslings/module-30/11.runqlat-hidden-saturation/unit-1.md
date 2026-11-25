---
title: "CPU at 60%, and a 2 ms handler has a 40 ms p99"
---

## The situation

`quote-api` (`127.0.0.1:8095`) does about two milliseconds of work per request.
Its p99 is many times that. The dashboard says the box has CPU to spare:

```
$ mpstat -P ALL 1 1 | tail -n +4
CPU    %usr   %sys  %idle
all   48.10   1.20  50.70
  0   99.00   1.00   0.00
  1   98.00   2.00   0.00
  2    0.00   0.00 100.00
  3    1.00   0.00  99.00
```

The first guess is that `quote-api` needs more CPU, so raise its cgroup quota.
Module 03's `cgroup-cpu-throttling` taught where that guess comes from, and
the same check rules it out here:

```
$ cat /sys/fs/cgroup/system.slice/quote-api.service/cpu.stat | grep throttled
nr_throttled 0
throttled_usec 0
```

Nothing is throttling it. It is not being *refused* CPU time; it is waiting in
line for it.

## Your objectives

- Measure how long `quote-api`'s threads wait for a CPU, with `runqlat`
- Find why, and fix it, keeping `nightly-reindex` running at full speed
- Measure again, and write `/root/answers/runqlat.md`:

```
before-p99-ms: <runqlat p99 for quote-api before the fix>
after-p99-ms: <runqlat p99 for quote-api after the fix>
cause: <why quote-api waits>
```

The scenario needs a Docker host with at least four CPUs.

## What you're being graded on

- `before-p99-ms` is a real before-the-fix figure (at least 4 ms), and
  `after-p99-ms` is lower; `cause` says which CPUs and what shares them
- `nightly-reindex` is running with all eight workers, on both its CPUs, with no
  CPU quota
- neither service's nice level, scheduling class or CPU weight has been changed
- `quote-api` may run on at least one CPU that `nightly-reindex` may not
- the grader measures `quote-api`'s run-queue wait while it sends it
  requests: at least 90% of waits are under **2 ms** (a shared host adds
  some noise, so the gate is looser than the p99 you report)

<details>
<summary>Hint 1 — the tool</summary>

`runqlat` cannot pick out one process inside this container (see *runqlat
inside a container*). This is its bpftrace version, `/usr/sbin/runqlat.bt`,
narrowed to `quote-api`:

```
bpftrace -e '
tracepoint:sched:sched_wakeup, tracepoint:sched:sched_wakeup_new { @q[args.pid] = nsecs; }
tracepoint:sched:sched_switch {
  if (args.prev_state == 0) { @q[args.prev_pid] = nsecs; }
  $ns = @q[args.next_pid];
  if ($ns && args.next_comm == "quote-api") { @ms = hist((nsecs - $ns) / 1000000); }
  delete(@q, args.next_pid); }
END { clear(@q); }'
```

Send requests while it runs (`while :; do curl -s 127.0.0.1:8095/ >/dev/null; done`),
then Ctrl-C.

</details>

<details>
<summary>Hint 2 — where it may run</summary>

```
taskset -cp $(systemctl show -P MainPID quote-api)
systemctl show -P CPUAffinity quote-api nightly-reindex
```

</details>

<details>
<summary>Hint 3 — the fix belongs in the unit</summary>

`CPUAffinity=` in a drop-in, then `systemctl daemon-reload` and a restart.

</details>

## Run-queue latency

When a thread wakes up — a request arrived on its socket — it becomes
*runnable*. If a CPU it is allowed on is free, it runs at once. If every such
CPU is busy, it joins that CPU's run queue and waits its turn. That wait is
invisible to every utilisation graph: the thread is not using CPU, and the CPU
is at 100% either way.

`runqlat` hooks the scheduler: it timestamps each wakeup and measures until
the thread actually gets on a CPU. The result is a histogram. With the script
from Hint 1, in milliseconds:

```
@ms:
[0]                   12 |@@                                                  |
[1]                    4 |                                                    |
[2, 4)                14 |@@@                                                 |
[4, 8)                61 |@@@@@@@@@@@@@                                       |
[8, 16)              231 |@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@|
[16, 32)              12 |@@                                                  |
```

The 99th percentile is the bucket where the running total reaches 99% of the
samples — here `[16, 32)`, so the p99 is up to 32 ms. A 2 ms handler that
waits 8–16 ms for a CPU before it starts has a latency of 10–20 ms, and none of
that time shows up as its own CPU usage.

## runqlat inside a container

`runqlat -p <pid>` prints an empty histogram here, and `runqlat -c <cgroup>`
prints one that is not about `quote-api`. The libbpf tools filter on PIDs as
the kernel knows them, in the *host* PID namespace, where `quote-api` has a
different number. And `-c` checks the cgroup of the task running when the
event fires, which at a wakeup is the *waker* — the client, or a softirq —
not the thread being woken. The bpftrace version matches on the woken
thread's name, which is the same from both sides. `quote-api` names itself
(`/proc/self/comm`) at start-up for exactly this.

## Why it waits

```
$ taskset -cp $(systemctl show -P MainPID quote-api)
pid 4318's current affinity list: 0,1
$ systemctl show -P CPUAffinity nightly-reindex
0 1
$ systemctl status nightly-reindex | grep -c 'sh -c'
8
```

Both services are pinned to CPUs 0 and 1. `nightly-reindex` runs eight
CPU-bound workers there. Every time `quote-api` wakes, it queues behind
whichever of eight busy threads is running, on two CPUs. CPUs 2 and 3 sit idle
because nothing is allowed to use them. The box average says 50% busy; the two
CPUs that matter are at 100%.

Fixes that look right and are not:

- **More quota.** Quota caps CPU time; it does not move a thread to another
  CPU.
- **Renice `quote-api`.** It now jumps the queue on two oversubscribed CPUs,
  and the next service pinned there waits instead. The cause is still there.
- **Throttle the batch job.** The queue gets shorter, and the reindex that has
  to finish tonight now does not.

The fix is to stop the two from sharing: give `quote-api` CPUs that nothing
CPU-bound is pinned to.

```
mkdir -p /etc/systemd/system/quote-api.service.d
printf '[Service]\nCPUAffinity=2 3\n' > /etc/systemd/system/quote-api.service.d/cpus.conf
systemctl daemon-reload && systemctl restart quote-api
```

On a real box, pinning is a deliberate choice: someone put both services on
0–1, probably to keep them off cores reserved for something else. Check what
2 and 3 are for before you move anything onto them.

## Checking yourself

Run the script again with requests flowing. Nearly every sample should land
in `[0]`.

<details>
<summary>Solution</summary>

```
# Hint 1's script, with requests running: p99 bucket [16, 32)
mkdir -p /etc/systemd/system/quote-api.service.d
printf '[Service]\nCPUAffinity=2 3\n' > /etc/systemd/system/quote-api.service.d/cpus.conf
systemctl daemon-reload && systemctl restart quote-api
# Hint 1's script again: nearly everything in [0]
```

```
before-p99-ms: 32
after-p99-ms: 1
cause: quote-api is pinned to CPUs 0-1, which nightly-reindex's eight CPU-bound workers saturate; 2-3 sit idle
```

</details>
