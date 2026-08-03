---
title: "One worker is eating the box — find which"
---

## The situation

Response times on `box` doubled about ten minutes ago. Nothing was deployed.
Load average is up and the machine feels sluggish over SSH.

Four processes are running: three queue workers and a cache warmer. All four
are meant to be there. One of them is the problem.

The instinct at 02:00 is to restart everything, and it would work — the CPU
graph would go flat and the alert would clear. It is also wrong: three of those
processes were serving traffic, and you would have taken them down without ever
finding out what happened.

## Your objectives

1. Establish *which* resource is saturated before touching anything.
2. Identify the single process responsible, with evidence.
3. Stop that one. Leave the other three running.

## What you're being graded on

Two things: that nothing is burning CPU any more, and that the three innocent
processes are still up. Killing the fleet fails the check.

<details>
<summary>Hint 1 — the 60-second checklist</summary>

Brendan Gregg's list for the first minute on a sick box. You don't need all of
it here, but the habit is the point:

```
uptime              # load average — is it climbing?
vmstat 1            # r column = runnable procs; is the CPU saturated or waiting?
mpstat -P ALL 1     # is it one core or all of them?
pidstat 1           # per-process CPU, refreshed — this is the one that names names
free -m             # is memory actually a problem, or does it just look big?
```

`vmstat 1` first. If `r` is high and `wa` is near zero, you have a CPU
saturation problem, not an I/O one — which tells you to go looking for a
process burning cycles rather than one stuck on disk.

</details>

<details>
<summary>Hint 2 — top's biggest number is not the answer</summary>

Sort `top` by memory and one process dwarfs everything else. Check whether it
is actually *doing* anything before you act on it:

```
pidstat 1 3
```

`%CPU` per process, sampled. A process holding 200 MB and using 0% CPU is
not why your load average is at 4. `free -m` will confirm there is plenty of
memory available.

One warning about reading its output: the `Command` column is the executable
name, so every Python process on this box shows up as `python3`. Once you have
a PID, `ps -o pid,args -p <pid>` tells you which script it is actually running.

Utilisation and saturation are different questions. Memory is *utilised*; the
CPU is *saturated*. Only one of those is causing the symptom.

</details>

<details>
<summary>Hint 3 — stopping just one</summary>

The workers run from a systemd template unit, so they are addressed
individually:

```
systemctl status 'queue-worker@*'
systemctl stop queue-worker@3.service
```

The `@` is a template instance — one unit file, one instance per argument.

</details>

<details>
<summary>Solution</summary>

Start with the checklist:

```
$ vmstat 1 3
procs -----------memory---------- ---swap-- -----io---- -system-- ------cpu-----
 r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st
 2  0      0 6431232  12288 231424    0    0     0     0  102  184 25  1 74  0  0
 2  0      0 6431232  12288 231424    0    0     0     0   98  177 25  0 75  0  0
```

`r` is 2, `wa` is 0. Runnable processes are queued and nothing is waiting on
I/O — CPU saturation.

Now find out who:

```
$ pidstat 1 3
UID       PID    %usr %system  %CPU   CPU  Command
0         214   99.00    1.00 100.00     3  python3
```

One process at 100%. Note what `pidstat` calls it: `python3`. The `Command`
column shows the process's `comm`, which is the executable — not the script it
is running. Four different Python processes all look identical here.

That is why the next step is not optional:

```
$ ps -o pid,args -p 214
  PID COMMAND
  214 /usr/bin/python3 /usr/local/bin/queue-worker 3
```

`args` gives the full command line, and there is the answer: instance 3.

Stop that one:

```
systemctl stop queue-worker@3.service
```

```
$ pidstat 1 2
UID       PID    %usr %system  %CPU   CPU  Command
0         198    0.00    0.00   0.00     1  queue-worker
0         206    0.00    0.00   0.00     0  queue-worker
0         221    0.00    0.00   0.00     2  cache-warmer
```

### What actually happened

Worker 3's polling loop lost its `sleep`. Instead of waiting half a second
between checks it spins, consuming a full core to do the same amount of work.
The other two workers run identical code with the sleep intact.

### The habit this is teaching

The USE method: for every resource, check **U**tilisation, **S**aturation, and
**E**rrors. It gives you a fixed list to walk instead of a hunch to follow, and
it is the difference between "the box is slow" and "the run queue is 2 deep
with no I/O wait, so something is CPU-bound".

The cache warmer is in this scenario on purpose. Under pressure the eye goes to
the largest number on the screen, and 200 MB resident looks like a smoking gun.
It isn't one. Measure the resource that matches the symptom.

</details>
