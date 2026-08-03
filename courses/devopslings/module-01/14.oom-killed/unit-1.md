---
title: "the worker that vanishes at 02:00 and leaves no note"
---

## The situation

The nightly report did not arrive. `report-builder` says it started and then
says nothing at all:

```
$ journalctl -u report-builder -o cat
report-builder: starting

$ ls -l /srv/reports/daily.csv
ls: cannot access '/srv/reports/daily.csv': No such file or directory
```

No traceback. No error. No "exiting" line. For a Python program that is
genuinely strange — even an unhandled exception prints a stack trace on the way
out. This one printed nothing, which means none of its code ran on the way out,
which means it did not get a way out.

The instinct at this point is to wrap the body in `try/except` and run it again
tomorrow. That will not catch anything, and the reason it will not catch
anything is the lesson.

## Your objectives

| file | answer |
|---|---|
| `/root/answers/killer` | one of `oom`, `segfault`, `exitcode`, `signal` |
| `/root/answers/limit` | the memory limit in effect when it died, **in bytes** |

Read the limit **before** you change anything.

Then make `report-builder` complete and write `/srv/reports/daily.csv`
containing all 20,000 orders. `report-builder.service` must still have a memory
limit — not `infinity`.

## What you're being graded on

Both answers, a report that matches the expected output byte for byte, and a
unit that still has a bound on its memory. Processing fewer records fits inside
any limit and is not the same as building the report.

<details>
<summary>Hint 1 — a process that leaves no message did not get to write one</summary>

Sort the ways a process can end by whether it gets a chance to speak:

| | last words? |
|---|---|
| chooses to exit | yes — return code, and usually a message |
| unhandled exception | yes — a traceback, printed by the runtime |
| `SIGTERM` | yes, if it has a handler |
| `SIGSEGV` | maybe — the runtime often prints something |
| **`SIGKILL`** | **no. The process is not scheduled again, ever** |

`SIGKILL` cannot be caught, blocked or handled. There is no `finally`, no atexit
hook, no flush. That is precisely consistent with what you are looking at: a
`starting` line that made it out, and total silence after.

So the question is not "what did the program do wrong". It is "who sent
`SIGKILL`, and why".

</details>

<details>
<summary>Hint 2 — ask systemd and the kernel, not the application</summary>

The application has no record because it never ran again. Two places do:

```
$ systemctl status report-builder.service
$ journalctl -u report-builder.service -o short --no-pager
```

systemd records how a unit died, including when the kernel killed it. Then the
kernel's own log:

```
$ journalctl -k --no-pager | tail -20
$ dmesg | tail -20
```

An OOM kill leaves an unmistakable block: the process name, its RSS, and the
memory cgroup it belonged to.

The cgroup keeps a counter too, which is the cleanest evidence of all:

```
$ systemctl show -p MemoryMax --value report-builder.service
$ cat /sys/fs/cgroup/system.slice/report-builder.service/memory.events
```

`oom_kill 1` means exactly one process in this unit's cgroup was killed for
memory. This is `find-the-evidence` from earlier in the module, applied: the
application's own log was never going to have it.

</details>

<details>
<summary>Hint 3 — the limit is not the bug</summary>

```
$ systemctl show -p MemoryMax --value report-builder.service
50331648
```

48 MiB. Record that number **now** — if you raise the limit first, the answer to
the second question is gone.

The tempting fix is to delete `MemoryMax=` or set it to `infinity`. Consider
what that actually does: the job still allocates hundreds of megabytes for work
that needs almost none, and instead of one unit dying, the kernel now picks a
victim from the whole box at 02:00. You have not fixed the failure, you have
widened its blast radius and made it someone else's service that dies.

Look at what the program holds on to:

```python
rows.append({... "pad": "x" * 4096})   # every row, retained
lines.append(...)                       # every row again, formatted
out.write("\n".join(lines))             # and a third copy, joined
```

Three full copies of a 20,000-row dataset live simultaneously, for a job that
needs one row at a time.

</details>

<details>
<summary>Solution</summary>

```
$ echo oom > /root/answers/killer
$ systemctl show -p MemoryMax --value report-builder.service > /root/answers/limit
```

```
$ journalctl -k | grep -i -A2 'killed process'
Memory cgroup out of memory: Killed process 812 (report-builder)
  total-vm:284916kB, anon-rss:47232kB, file-rss:3200kB

$ cat /sys/fs/cgroup/system.slice/report-builder.service/memory.events
oom 2
oom_kill 1
```

And the fix — stream it:

```python
with open("/srv/reports/orders.tsv") as f, open("/srv/reports/daily.csv", "w") as out:
    out.write("order_id,sku,qty,unit_price,total\n")
    for line in f:
        oid, sku, qty, price = line.rstrip("\n").split("\t")
        qty, price = int(qty), float(price)
        out.write(f"{oid},{sku},{qty},{price:.2f},{qty*price:.2f}\n")
```

Peak memory is now one row, whatever the input size. `MemoryMax=48M` stays
exactly where it was.

### Why this is a lesson at all

Three things, in increasing order of how much time they save you.

1. **Silence is a signal with a short list of causes.** A process that exits
   without a word was not scheduled again. In practice that means `SIGKILL`,
   and in practice that means the OOM killer or something equally
   external — not a bug in the program's error handling. Adding `try/except`
   here would have produced another silent night and a wasted day.

2. **The record is never where the application would have put it.** The kernel
   logs the kill, systemd logs the unit's death, the cgroup counts it. The
   application logs nothing, because it was not running. Knowing which of those
   to read is the whole of `find-the-evidence`, and this is the case that most
   punishes not knowing.

3. **A limit that fires is doing its job.** The reflex — the limit killed my
   process, so remove the limit — inverts cause and effect. The limit is what
   turned "a memory bug takes down the box at 02:00" into "one unit fails and
   everything else keeps running". Removing it does not fix the allocation; it
   removes the containment and hands the failure to whichever service the
   kernel picks next. Raise it deliberately if the workload genuinely needs
   more. Delete it only if you want the whole machine to be the blast radius.

</details>
