---
title: "load average 4, and top shows nothing above 2%"
---

## The situation

The box is loaded and nothing in `top` is responsible:

```
$ uptime
 10:14:02 up 3 days,  load average: 4.02, 3.87, 3.55
$ top -b -n1 | head -12
    PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
    211 root      20   0    7.2m   3.9m   3.4m S   1.3   0.1   0:41.10 inventory-sync
      1 root      20   0   21.0m  12.1m   9.2m S   0.0   0.2   0:03.02 systemd
     ...
```

Every refresh shows the same quiet daemons. The first guess is to keep
watching `top`, or switch to `htop` and sort differently. Neither will find
it. `top` reads `/proc` once per refresh; a process that starts, runs for two
milliseconds and exits between refreshes never appears in any of them, and
hundreds of them a second never appear either. Their CPU is real, it just
belongs to processes that no longer exist by the time anyone looks.

## Your objectives

- Catch the short-lived processes as they start, and name the long-lived
  parent that keeps spawning them
- Fix the parent so it stops forking at that rate, while it keeps doing its
  job
- Write `/root/answers/forks.md`:

```
parent: <the process that spawns them>
```

Killing the parent is not a fix. A timer restarts it within fifteen seconds,
and the job it does is needed.

## What you're being graded on

- `parent` names the spawner
- over five seconds, the processes forked inside that service's cgroup stay
  under **30 a second**
- the service is still running, `/var/lib/inventory/hosts.txt` is rewritten
  at least every five seconds, and its content is byte-for-byte what it was before the fix

<details>
<summary>Hint 1 — catching an exec</summary>

```
execsnoop
```

One line per `execve`: what ran, and how often. To name who starts them, count
forks by the parent's name:

```
bpftrace -e 'tracepoint:sched:sched_process_fork { @[comm] = count(); }'
```

</details>

<details>
<summary>Hint 2 — counting without a tracer</summary>

```
grep processes /proc/stat; sleep 1; grep processes /proc/stat
```

`processes` counts every fork since boot. The difference is forks per second,
for the whole kernel.

</details>

<details>
<summary>Hint 3 — where the forks come from</summary>

In bash, `$(...)` starts a subshell, and every command in a pipeline is a
process. `$(echo "$h" | tr A-Z a-z)` is at least three, per host, per pass.

</details>

## Seeing every exec

`execsnoop` hooks process creation in the kernel and prints a line for every
`execve` as it happens:

```
$ execsnoop
PCOMM            PID     PPID    RET ARGS
tr               48211   48209     0 /usr/bin/tr A-Z a-z
cut              48214   48212     0 /usr/bin/cut -d. -f1
tr               48217   48215     0 /usr/bin/tr A-Z a-z
cut              48220   48218     0 /usr/bin/cut -d. -f1
...
```

It scrolls faster than you can read, which is itself the first finding. On a
host, the next step is `ps -o pid,ppid,comm -p <PPID>` up the chain until it
lands on something that stays. Inside this container that finds nothing: the
libbpf tools print PIDs as the kernel knows them, in the *host* PID namespace,
and `ps` here only knows the container's numbers. A fork tracepoint fires in
the parent, so bpftrace's `comm` is the parent's name, which needs no PID at
all:

```
$ bpftrace -e 'tracepoint:sched:sched_process_fork { @[comm] = count(); }'
^C
@[python3]: 77
@[bash]: 363
@[inventory-sync]: 1785
```

The tools trace the whole kernel, so other containers' processes show up too.
A bash script's processes carry the script's name, and so do the subshells it
forks for `$(...)`. The parent is the job itself.

`execsnoop` attaches to `syscalls:sys_enter_execve`. On kernels that deliver
the per-syscall tracepoints to BPF only for CPU 0 — Ubuntu's 7.0 kernels, for
one — it shows a fraction of the execs. A fraction of several hundred a second is
still plenty to name the parent; it is not a number to measure the fix with.
`/proc/stat`'s `processes` counter, or a `sched:` tracepoint, counts all of
them.

## The fix

`inventory-sync` lower-cases each hostname and cuts it at the first dot:

```bash
lower=$(echo "$h" | tr 'A-Z' 'a-z')
short=$(echo "$lower" | cut -d. -f1)
```

Two command substitutions, each a subshell plus a pipeline, for each of 120
hosts, every second. bash can do both without starting anything:

```bash
lower=${h,,}           # lower-case
short=${lower%%.*}     # strip the longest ".*" suffix
```

A pass over the inventory then forks for `mv` and `sleep` only.

Two shortcuts the grader rejects: slowing the loop down (`sleep 30`) cuts the
rate by doing less work and leaves `hosts.txt` stale, and stopping the timer
leaves the job dead and the file going stale with it.

## Checking yourself

```
systemctl restart inventory-sync
a=$(awk '/^processes/{print $2}' /proc/stat); sleep 5; b=$(awk '/^processes/{print $2}' /proc/stat); echo $(( (b - a) / 5 ))/s
cat /var/lib/inventory/hosts.txt | head -3
```

The host-wide count includes everything else on the kernel, so it will not
reach zero; it should drop by hundreds.

<details>
<summary>Solution</summary>

`/usr/local/bin/inventory-sync`:

```bash
#!/bin/bash
out=/var/lib/inventory/hosts.txt
while :; do
  : > "$out.tmp"
  while read -r h; do
    lower=${h,,}
    echo "${lower%%.*} $lower" >> "$out.tmp"
  done < /etc/inventory/hosts
  mv "$out.tmp" "$out"
  sleep 1
done
```

```
systemctl restart inventory-sync
```

```
parent: inventory-sync
```

</details>
