---
title: "the export that has been running for nine hours at 0% CPU"
---

## The situation

The nightly order export kicks off at 03:00 and normally takes about forty
seconds. It is 12:00 and it is still going.

```
$ systemctl status export-orders.service
● export-orders.service - Nightly order export
     Active: activating (start) since 03:00:04; 9h ago

$ ls -l /srv/exports/
total 0
```

No output. No error. Nothing in the journal since it started. And the thing
that makes this different from every other stuck job you have met:

```
$ ps -o pid,stat,time,%cpu,cmd -p "$(systemctl show -p MainPID --value export-orders.service)"
    PID STAT     TIME %CPU CMD
    412 S     00:00:00  0.0 /bin/sh -c /usr/local/bin/export-orders > /var/spool/export/orders.fifo
```

Nine hours of wall clock, zero seconds of CPU. It is not spinning, it is not
thrashing, it is not slowly grinding through a large file. It is asleep, and it
has been asleep since four seconds after it started.

## Your objectives

**First**, while it is still blocked, record what it is waiting in:

| file | contents |
|---|---|
| `/root/answers/wchan` | the kernel function the export is sleeping in, verbatim, and nothing else |

**Then** make the export complete, producing `/srv/exports/orders.csv`.

Do this in that order. Repairing the pipeline is what lets the process exit,
and once it exits there is no `/proc/<pid>` to read. If you lose it, `reset` the
lesson.

## What you're being graded on

The recorded `wchan`, and a pipeline that genuinely works — the check stops both
units, deletes the output, runs the whole thing again from scratch, and compares
the bytes that come out against a fingerprint. It also checks the pipe is still
a pipe.

<details>
<summary>Hint 1 — a process at 0% CPU is not stuck, it is waiting</summary>

This distinction is the whole lesson. Two very different states look identical
in "it's been running for hours":

- **Spinning** — high CPU, making no progress. A loop with no exit condition.
  `top` shows it. Profiling finds it.
- **Blocked** — zero CPU, making no progress. It made a system call and the
  kernel has not returned from it yet.

`STAT` tells you which:

```
$ ps -o pid,stat,cmd -p <pid>
```

`R` is running. `S` is interruptible sleep — waiting on something that could
take a while, and killable. `D` is uninterruptible sleep — usually waiting on
disk or an unresponsive filesystem, and famously not killable.

This one is `S`. It is waiting on something, and Linux will tell you what.

</details>

<details>
<summary>Hint 2 — ask the kernel what it is waiting in</summary>

`/proc/<pid>/wchan` holds the name of the kernel function the task is currently
sleeping in:

```
$ pid=$(systemctl show -p MainPID --value export-orders.service)
$ cat /proc/$pid/wchan; echo
```

If you want the whole path rather than the innermost frame:

```
$ sudo cat /proc/$pid/stack
```

That prints the kernel stack, and the second and third frames name the syscall
it is stuck inside. Between them, `wchan` says *what* it is waiting for and
`stack` says *how it got there*.

Copy the `wchan` value into `/root/answers/wchan` now, before you do anything
else.

</details>

<details>
<summary>Hint 3 — what it is waiting for</summary>

Look at what the command actually does:

```
/bin/sh -c '/usr/local/bin/export-orders > /var/spool/export/orders.fifo'
$ ls -l /var/spool/export/orders.fifo
prw-r--r-- 1 root root 0 Aug  3 03:00 /var/spool/export/orders.fifo
```

`p` in the first column. That is not a file, it is a **named pipe**.

Opening a FIFO for writing blocks until some process opens the same FIFO for
reading. That is not a bug or a timeout — it is the defined behaviour, and it is
what makes a FIFO a rendezvous point rather than a buffer.

So the export is not broken. It is waiting for its reader, and its reader never
turned up.

```
$ lsof /var/spool/export/orders.fifo
COMMAND  PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
sh       412 root    1w  FIFO   0,24      0t0  ... /var/spool/export/orders.fifo
```

One writer. No reader.

</details>

<details>
<summary>Hint 4 — find the reader that never arrived</summary>

Something is supposed to be on the other end.

```
$ systemctl list-units --all --failed
UNIT                      LOAD   ACTIVE SUB    DESCRIPTION
● orders-shipper.service  loaded failed failed Ship the order export
```

It has been failed since 03:00 — before the export even blocked — and nothing
ever connected the two.

```
$ systemctl status orders-shipper.service
     Active: failed (Result: exit-code) since 03:00:04
   cat: /var/spool/export/order.fifo: No such file or directory
```

Read that path against the one the export writes to, character by character.

</details>

<details>
<summary>Solution</summary>

### The evidence

```
$ pid=$(systemctl show -p MainPID --value export-orders.service)
$ cat /proc/$pid/wchan; echo
wait_for_partner

$ cat /proc/$pid/stack
[<0>] wait_for_partner+0x84/0x100
[<0>] fifo_open+0x138/0x2a8
[<0>] vfs_open+0x118/0x4a8
```

`wait_for_partner`, inside `fifo_open`. The kernel is telling you, in one word,
that this is a FIFO waiting for its other end. Not a deadlock, not a slow query,
not a hung mount.

```
$ echo wait_for_partner > /root/answers/wchan
```

### The cause

```
$ grep ExecStart /etc/systemd/system/orders-shipper.service
ExecStart=/bin/sh -c 'cat /var/spool/export/order.fifo > /srv/exports/orders.csv'
```

`order.fifo`. The pipe is `orders.fifo`. One missing character, in a path that
nobody reads aloud.

```
$ sed -i 's#/order\.fifo#/orders.fifo#' /etc/systemd/system/orders-shipper.service
$ systemctl daemon-reload
$ systemctl start --no-block orders-shipper.service
```

The moment the reader opens the FIFO, the writer's nine-hour-old `open()`
returns and the export runs to completion in under a minute.

### Why this is a lesson at all

The instinct with a job that has been running too long is to restart it. Here
that is exactly wrong twice over. It destroys the only evidence — the blocked
process — and the restarted job blocks in precisely the same place, because
nothing about the producer was ever broken.

Three things worth keeping:

1. **Zero CPU is a diagnosis, not a symptom.** A process burning no CPU and
   making no progress is blocked in a syscall. You do not need a profiler, a
   debugger, or the application's source. You need to ask the kernel which call
   it is in, and `/proc/<pid>/wchan` answers in one word.

2. **The failure and the symptom were hours and one unit apart.** The shipper
   failed at 03:00:04 and its failure was invisible — a unit that exits
   non-zero at 3am and is not the thing anyone monitors. The export was still
   "active" the whole time, which reads as healthy on every dashboard. The
   thing that was paging was not the thing that was broken. This is the normal
   shape of an incident, not an unusual one.

3. **FIFOs block on open by design.** A named pipe is a rendezvous, not a
   buffer: `open()` for write waits for a reader, `open()` for read waits for a
   writer, and once both are attached the 64 KiB kernel buffer means the writer
   also blocks whenever the reader falls behind. Any pipeline built out of one
   inherits that coupling. It is a fine mechanism, and it is a terrible one to
   discover at 03:00 with no timeout anywhere in the chain.

The general habit — *ask the kernel what the process is waiting for, before you
restart it and lose the answer* — is what makes the difference between a
ten-minute incident and a nine-hour one.

</details>
