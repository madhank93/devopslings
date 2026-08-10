---
title: "the batch job that got nine times slower on a box with memory to spare"
---

## The situation

`ledger-rollup` used to finish a pass in well under a second. It now takes
several seconds per pass. The box it runs on has gigabytes of free memory and an
idle CPU graph, and nothing about the ledger changed.

```
$ free -m
               total        used        free      shared  buff/cache   available
Mem:            7962        1204        5918          12         840        6612

$ systemctl status ledger-rollup
   Active: active (running)
   Memory: 199.4M
```

200 MB of memory used on a box with 5.9 GB free. By every number on that screen,
this job is comfortable.

## Your objectives

| file | answer |
|---|---|
| `/root/answers/evidence` | one of `anon`, `file`, `pgfault`, `pswpin` |

Then make the job fast again, under the same input. The check watches the pass
counter and requires the rate to recover.

Two things it will not accept:

- a smaller ledger. `LEDGER_MB` stays at 300 — the job's work is the job.
- a `vm.swappiness` change. That knob is machine-wide here.

## What you're being graded on

The named counter, and at least 120 passes in a ten-second window with the
service alive throughout and `vm.swappiness` where it started. A job that was
OOM-killed during the check fails, and so does one whose pass counter went
backwards, because that means it died and restarted rather than made progress.

<details>
<summary>Hint 1 — "free memory" and "memory this job may use" are different numbers</summary>

`free` describes the machine. It has nothing to say about what any individual
job is allowed to touch. That limit lives on the unit:

```
$ systemctl show -p MemoryMax -p MemorySwapMax ledger-rollup
MemoryMax=209715200
MemorySwapMax=2147483648
```

200 MB, on a box with 5.9 GB free. The job is not short of the machine's memory.
It is short of its own, and 2 GB of swap is standing by to absorb the difference
— which is exactly why the symptom is slowness rather than a crash.

A limit like that is usually set from what a job *reported using* at some point,
which is not the same as what it *has to touch*.

</details>

<details>
<summary>Hint 2 — the counter that separates large from paging</summary>

`memory.current` and `anon` tell you how much the job holds right now. Both look
the same whether the job fits comfortably or is fighting for every page. Size is
not motion.

```
$ cg=/sys/fs/cgroup$(systemctl show -p ControlGroup --value ledger-rollup)
$ grep -E '^(anon|file|pgfault|pswpin|pswpout) ' $cg/memory.stat
anon 205438976
file 0
pgfault 41883924
pswpin 1340523
pswpout 1367007
```

- **`anon`** — how much anonymous memory is held. Pinned at the limit, as it
  would be for any job that fills its allowance.
- **`file`** — page cache. Zero: this job's memory is its own heap, and there is
  no file behind it to drop and re-read.
- **`pgfault`** — minor faults. In the tens of millions on a perfectly healthy
  box, just from touching memory that is already there.
- **`pswpin`** — pages read back *in* from swap. This only moves when a page the
  job needs is not in memory any more and has to be fetched.

Read `pswpin` twice, ten seconds apart, and multiply the difference by 4 KiB.
That is the volume of memory this job is re-reading from swap to do work it
already had the memory for once.

</details>

<details>
<summary>Hint 3 — why this job in particular, and why the obvious fixes are worse</summary>

The rollup touches all 300 MB on every pass, in key order rather than address
order. That detail is doing a lot of work here. Read in address order, the kernel
sees the pattern coming and reads ahead, and a working set that overflows its
limit costs surprisingly little. Read by key, every miss is its own trip, and
nothing can be predicted.

So the job needs 300 MB resident and is allowed 200 MB. A third of its working
set is evicted and fetched back, continuously, forever.

Two fixes suggest themselves and both are worse:

- **Turn swap off** (`MemorySwapMax=0`). The overflow has nowhere to go, so the
  kernel kills the job instead. Slow becomes dead. Swap is not what is wrong
  here; it is the only reason the job is still running at all.
- **Lower `vm.swappiness`.** It biases reclaim towards evicting page cache
  instead of anonymous memory — and this job has no page cache, so there is
  nothing else to evict. It would also apply to every process on the machine,
  which this box shares with its host. A machine-wide retune to fix one unit is
  not a fix, it is a bill somebody else pays.

</details>

<details>
<summary>Solution</summary>

Size the limit to what the job touches, in a drop-in rather than an edit of the
packaged unit:

```
# /etc/systemd/system/ledger-rollup.service.d/10-memory.conf
[Service]
MemoryMax=512M
```

```
$ systemctl daemon-reload
$ systemctl restart ledger-rollup
```

The pass rate returns to around 230 in ten seconds, and `pswpin` stops moving.

The general shape of this one: a job that is slow while the machine is idle, with
memory it is not allowed to use sitting free next to it. The machine's numbers
said everything was fine, because the machine was fine. The limit was somewhere
else, and the counter that proved it — `pswpin` — is one nobody graphs.

Two boundaries worth carrying out of this lesson. `MemoryMax` and
`MemorySwapMax` are per-unit and genuinely yours. `vm.swappiness` and
`/proc/swaps` are the machine's, shared with the host this container runs on, and
tuning them to fix one job changes every other job on the box.

</details>
