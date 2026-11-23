---
title: "70% system time, and nothing hot in the code"
---

## The situation

`spooler` streams settlement records into `/var/spool/spooler/stream.log` at
a steady megabyte a second for the downstream loader. It uses most of a core
to do it:

```
$ pidstat -u -p "$(systemctl show -p MainPID --value spooler.service)" 1 3
  UID       PID    %usr %system  %CPU   Command
  999       412    6.00   68.00 74.00   spooler
```

`%system` is time the CPU spent in the kernel on this process's behalf.
Someone profiled the spooler's own code and found nothing: `main`, `emit`,
`put`, each a sliver, no hot loop. The proposal is to tune a sysctl, on the
theory that the kernel is slow.

The kernel is doing what it is asked to. The question is what it is being
asked.

## Profiling the kernel side

A user-space profiler (py-spy, a language's own profiler) sees only the
program's own frames. `perf` samples the whole stack, through the system call
and into the kernel:

```
pid=$(systemctl show -p MainPID --value spooler.service)
perf record -F 999 -e cpu-clock -g -p "$pid" -- sleep 5
perf report --stdio --no-children | head -60
```

- `-e cpu-clock` samples on a software timer. ARM64 hosts and many VMs lack
  the hardware cycle counters perf uses by default; `cpu-clock` works
  everywhere.
- `-g` records the call stack of each sample, kernel frames and user frames.
- `perf top -g -p "$pid"` shows the same thing live.

On the kernel side, a system call enters through an architecture-specific
stub (`__arm64_sys_write`, `__x64_sys_write`) and then the generic code
(`ksys_write`, `vfs_write`, the filesystem's write function). The stub's name
is the system call.

Then ask *how* it is being called. `/proc/<pid>/io` counts bytes written
(`wchar`) and write system calls (`syscw`) since the process started; `strace
-p <pid> -e trace=write` shows a few calls and their sizes.

## Your objectives

1. Write the system call and its size to `/root/answers/systime.txt`:

   ```
   syscall=<the system call>
   bytes_per_call=<bytes each call writes>
   ```

2. Fix `/usr/local/src/spooler/spooler.c` (`make -C /usr/local/src/spooler
   install`, then restart the unit) so the spooler spends at most a tenth of
   the system time per megabyte it did.

## What you're being graded on

The check reads your answer, then measures the running spooler for three
seconds from `/proc/<pid>/stat` (`stime`) and `/proc/<pid>/io` (`wchar`): the
system time per MiB written must be at most a tenth of what the scenario
measured at start, at no less than 90% of the original rate, and the file must
still hold every record, whole and in sequence.

<details>
<summary>Hint 1 — reading the report</summary>

With `--no-children`, each entry is the function the sample was *in*, with
the stack that led there below it. Most of the time is spread across kernel
functions, but follow any of their stacks down and they meet at the same
system call entry. Then compare `wchar` and `syscw` in `/proc/<pid>/io`.

</details>

<details>
<summary>Hint 2 — what a system call costs</summary>

Every system call pays a fixed cost to enter and leave the kernel, plus
locking and bookkeeping in the filesystem, whatever the size. One byte per
call pays that a million times a second. Hand the kernel each record, or
each tick's worth of records, in one call.

</details>

<details>
<summary>Solution</summary>

```
    68.12%  spooler  [kernel.kallsyms]  [k] ...
            |
            ---write
               el0_svc
               __arm64_sys_write
               ksys_write
               vfs_write
               ...
$ grep -E 'wchar|syscw' /proc/$pid/io
wchar: 61203348
syscw: 61203348
```

```
syscall=write
bytes_per_call=1
```

`put()` writes each byte with its own `write()`:

```c
    for (size_t i = 0; i < n; i++)
        write(fd, s + i, 1);
```

Write the record in one call:

```c
    write(fd, s, n);
```

That is about 60 bytes per call, sixty times fewer kernel entries, and system
time per megabyte falls accordingly. Buffering a whole tick (`fwrite` through
stdio and an `fflush` per tick, or building the 10 KB in memory) cuts it by
another two orders of magnitude.

### Where one-byte writes come from

- Unbuffered output: `python -u`, `PYTHONUNBUFFERED`, `stdbuf -o0`, a logger
  that writes each field separately, `setvbuf(..., _IONBF, ...)`.
- `dd bs=1` and loops that copy a byte at a time.
- Same pattern on the read side: `strace -c` on a slow parser often shows
  millions of one-byte `read()`s.

`%system` high and user code flat almost always means the program is making
many small system calls. No sysctl changes what one costs by a factor of
sixty.

</details>
