---
title: "four questions about a busy box"
---

## The situation

`busy.service` runs four Python workers: `ledger`, `indexer`, `mailer` and
`tailer`. The box feels loaded, and `top` shows four `python3` processes
trading places at the top of the list, none above a few percent. Before
deciding what to look at, you want four answers:

1. Which worker makes the most syscalls?
2. Which process opens files under `/etc`, and which files?
3. Which worker reads the most bytes, and how many per second?
4. How long does `tailer`'s slowest `read()` take?

`top` and `ps` cannot answer any of them. They sample state; these are
questions about *events*, and only something hooked into the kernel sees every
event. That is what bpftrace is for: a one-line program attached to a kernel
probe, aggregating as it goes, printing when you press Ctrl-C.

## Your objectives

- Save one bpftrace program per question in `/root/oneliners/`: `q1.bt`,
  `q2.bt`, `q3.bt`, `q4.bt` (`/root/questions.txt` says exactly what each one
  answers)
- Run each, read the answer, and write `/root/answers/oneliners.md`:

```
most-syscalls: <process>
etc-opener: <process>
etc-files: <file>, <file>, ...
most-bytes: <process>
bytes-per-second: <number>
slowest-read-ms: <number>
```

## What you're being graded on

- every answer matches what the workers were doing while you traced them
- then the grader gives the workers new roles, new files, a new byte rate and
  a new slow read, re-runs your four programs, and expects each one's output to
  show the *new* answer: `q1.bt` and `q3.bt` must print `@[comm]: N` maps,
  `q2.bt` a line per open naming the process and the path, and `q4.bt` the
  slowest read as a map value (`@max: N`, in ns, µs or ms)

A program that prints a remembered answer, or that happens to work on your
four-core laptop and not on the grader's box, fails the second half.

<details>
<summary>Hint 1 — probes and maps</summary>

```
bpftrace -l 'tracepoint:raw_syscalls:*'
bpftrace -lv 'tracepoint:raw_syscalls:sys_exit'
```

`@[comm] = count();` keeps one counter per process name; bpftrace prints
every map when it exits, sorted with the largest last.

</details>

<details>
<summary>Hint 2 — what read() returned, not what it asked for</summary>

The bytes a read actually got are its *return value*, which exists only on
the way out: `sys_exit`'s `args->ret`. Negative returns are errors.

</details>

<details>
<summary>Hint 3 — timing one call</summary>

Store `nsecs` in a map keyed by the thread (`curtask->pid`) on enter,
subtract on exit, delete the key. `max()` keeps the largest.

</details>

## Two kinds of syscall tracepoint

The kernel offers two ways in:

```
tracepoint:syscalls:sys_enter_openat   one per syscall, arguments by name
tracepoint:raw_syscalls:sys_enter      every syscall, as a number plus args[0..5]
```

The per-syscall ones read better, and every bpftrace tutorial uses them:

```
bpftrace -e 'tracepoint:syscalls:sys_enter_openat { printf("%s %s\n", comm, str(args->filename)); }'
```

On some kernels they are quietly wrong. Ubuntu's 7.0 kernels — the ones on
GitHub's runners — hand `syscalls:sys_enter_*` events to BPF only for syscalls
made on CPU 0. On a four-CPU box the program above prints about one open in
four, and nothing about the output tells you so. `raw_syscalls:sys_enter` and
`sys_exit` fire on every CPU everywhere, so every program here uses them. The
price is that the syscall is a number, and the number depends on the
architecture:

| syscall | x86_64 | arm64 (aarch64) |
|---|---|---|
| read | 0 | 63 |
| openat | 257 | 56 |

`uname -m` says which column you are in. The arguments come in the order the
man page lists them: `openat(dirfd, pathname, flags)` puts the path in
`args->args[1]`. It is a pointer into the process's memory, so read it with
`str(uptr(args->args[1]))`.

## The four programs

The examples use x86_64 numbers.

Every probe here sees the whole kernel, not just this container: the
Docker host's other containers show up in the maps too. That is fine for
these questions; just read the names.

**Who makes the most syscalls.** Count every syscall, keyed by process name:

```
tracepoint:raw_syscalls:sys_enter { @[comm] = count(); }
```

**Who opens what under /etc.** Filter on openat and the path prefix, print
both:

```
tracepoint:raw_syscalls:sys_enter
/args->id == 257 && strncmp(str(uptr(args->args[1])), "/etc/", 5) == 0/
{ printf("%s %s\n", comm, str(uptr(args->args[1]))); }
```

**Who reads the most bytes.** Sum read's return value on exit, positive
returns only:

```
tracepoint:raw_syscalls:sys_exit /args->id == 0 && args->ret > 0/ { @[comm] = sum(args->ret); }
```

Run it for ten seconds and divide, or add `interval:s:1 { print(@); clear(@); }`
to get a per-second line.

**How long the slowest read takes.** Two probes and a map in between:

```
tracepoint:raw_syscalls:sys_enter /args->id == 0 && comm == "tailer"/ { @start[curtask->pid] = nsecs; }
tracepoint:raw_syscalls:sys_exit /args->id == 0 && @start[curtask->pid]/ { @max_ns = max(nsecs - @start[curtask->pid]); delete(@start[curtask->pid]); }
END { clear(@start); }
```

The exit filter ties an exit to the read that started the clock: the same
syscall number, on a thread with a pending start time. `END { clear(@start); }`
stops bpftrace printing the leftover timestamps when you stop it.

Why `curtask->pid` and not bpftrace's `tid`: inside a container, bpftrace may
print

```
WARNING: Invalid argument
Additional Info - helper: get_ns_current_pid_tgid, retcode: -22
```

That is bpftrace failing to translate thread IDs into the container's PID
namespace. `tid` and `pid` then come back as 0 for every process outside the
box, and on some boots for the box's own threads too. Keyed on `tid`, tailer's
start time then shares key 0 with every other process on the kernel, and any
of their `read`s returning ends tailer's timing. `curtask->pid` is the
kernel's own thread ID, read straight from the task, and tells threads apart
in any namespace. On a plain host `tid` works too.

`tailer` reads a pipe two bytes at a time, so most of its reads return in
microseconds. Once a second the writer pauses, and one read waits the whole
pause. An average would bury it under a hundred fast reads; `max()` and
`hist()` do not.

## Checking yourself

Run each program for a few seconds with `bpftrace /root/oneliners/q1.bt` and
Ctrl-C. Then run `/root/oneliners/q1.bt` again after `systemctl restart
busy.service` — the roles stay the same until the grader reshuffles them, so
the output should agree with itself.

<details>
<summary>Solution</summary>

On arm64 replace 0 with 63 (read) and 257 with 56 (openat).

```
# q1.bt
tracepoint:raw_syscalls:sys_enter { @[comm] = count(); }

# q2.bt
tracepoint:raw_syscalls:sys_enter
/args->id == 257 && strncmp(str(uptr(args->args[1])), "/etc/", 5) == 0/
{ printf("%s %s\n", comm, str(uptr(args->args[1]))); }

# q3.bt
tracepoint:raw_syscalls:sys_exit /args->id == 0 && args->ret > 0/ { @[comm] = sum(args->ret); }

# q4.bt
tracepoint:raw_syscalls:sys_enter /args->id == 0 && comm == "tailer"/ { @start[curtask->pid] = nsecs; }
tracepoint:raw_syscalls:sys_exit /args->id == 0 && @start[curtask->pid]/ { @max_ns = max(nsecs - @start[curtask->pid]); delete(@start[curtask->pid]); }
END { clear(@start); }
```

Read the largest worker entry from q1 and q3 (bpftrace sees every process on
the kernel, so another container may top the list), the process and paths from
q2's lines, divide q3's total by the seconds it ran, and divide q4's `@max_ns`
by 1,000,000.

</details>
