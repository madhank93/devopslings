---
title: "the refund limit changed at 02:14 and nobody admits to it"
---

## The situation

`/etc/pay/limits.conf` caps refunds at 500. Last night at 02:14 it said 50000.
Finance put it back; it changed again. Several people and services can write
the file, and nobody admits to it.

```
$ stat -c '%y %U' /etc/pay/limits.conf
2026-11-17 02:14:00 root
$ grep limits /home/alice/.bash_history
vi /etc/pay/limits.conf
```

The first guess writes itself: alice did it, at 02:14. Neither piece of evidence
says that. mtime says *when* the content last changed, not who changed it, and
it moves again on the next write. Shell history says what alice typed into one
shell — not whether she saved, not what any other process did, and it is a file
she can edit.

## Your objectives

- Write `/root/watch.bt`, a bpftrace program that prints one line for every
  change to `/etc/pay/limits.conf`, naming the user (name or uid), the process
  (comm) and the syscall
- Run it, catch the next change, and say who it was

## What you're being graded on

The grader runs your watch, then reads the file, appends to it, edits it with
`sed -i`, and writes a different file in `/etc/pay`, each as a different user
and through a process name it makes up on the spot:

- the append and the `sed -i` each produce a line naming their user
- the read and the other file produce nothing

`/root/answers/who.md`:

```
user: <who changed it>
process: <the process that wrote it>
syscall: <the syscall your watch caught it in>
```

<details>
<summary>Hint 1 — where a write starts</summary>

The kernel checks write permission when the file is *opened*, so that is where
the path and the intent meet: `openat(2)`, with `O_WRONLY` or `O_RDWR` in the
flags. `write(2)` only has a file descriptor. Tracepoints carry the arguments:

```
$ bpftrace -lv 'tracepoint:syscalls:sys_enter_openat'
```

</details>

<details>
<summary>Hint 2 — the change that never opens the file</summary>

`sed -i`, `vi`, `ansible` and most config tools write a temporary file next to
the target and `rename(2)` it over the top. The target path never appears in
an `openat` for writing; it appears as rename's `newname`. Which rename syscall
glibc uses differs by CPU, so `tracepoint:syscalls:sys_enter_rename*` covers
them all.

</details>

<details>
<summary>Hint 3 — reads are not changes</summary>

`O_RDONLY` is 0. The access mode is the low two bits of the flags, so
`(args->flags & 3) != 0` is "opened for writing".

</details>

## A trail, not a guess

The question "who changed this file" is only answerable from a record made *at
the moment of the change*, by something the changer could not skip. After the
fact you have the content, the mtime and whatever people choose to tell you.
The kernel is the only party that sees every write, because every write has to
ask it.

On a normal Linux host that record is the audit subsystem:

```
$ auditctl -w /etc/pay/limits.conf -p wa -k refund-limit
$ ausearch -k refund-limit -i
type=SYSCALL ... syscall=openat ... auid=unset uid=svc-cache comm=warm exe=/usr/bin/bash
```

`-w` watches the path, `-p wa` asks for writes and attribute changes and leaves
reads out, `-k` tags the records so you can find them. It is the tool to use
when you have it, and it has one thing bpftrace does not: `auid`, the login
user, which survives `sudo` and `su`.

This box cannot run it. The kernel has audit compiled in, but the audit socket
only answers processes in the host's initial PID namespace, and a container —
even a privileged one — is not in it. bpftrace attaches to the same syscalls
from inside a privileged container, so the watch here is a bpftrace program.
The skill is the same one: decide which syscalls count as a change to the path,
record who made them, and leave the reads out.

## Writing the watch

The in-place writer is the straightforward one:

```
tracepoint:syscalls:sys_enter_openat
/ str(args->filename) == "/etc/pay/limits.conf" && (args->flags & 3) != 0 /
{
  printf("%s uid=%d comm=%s syscall=%s\n",
         strftime("%H:%M:%S", nsecs), uid, comm, probe);
}
```

That catches `echo >> limits.conf` and a bash script redirecting into the file.
It misses `sed -i` entirely: sed opens the original only to *read* it, writes
`/etc/pay/sedXXXXXX`, and renames that over the target. That is why auditd's
`-w` is a watch on the *path*, and a rename onto it counts:

```
tracepoint:syscalls:sys_enter_rename*
/ str(args->newname) == "/etc/pay/limits.conf" /
{
  printf("%s uid=%d comm=%s syscall=%s\n",
         strftime("%H:%M:%S", nsecs), uid, comm, probe);
}
```

The filter compares the path as the process passed it. A process that `cd`s to
`/etc/pay` and writes `limits.conf` slips past it, which auditd's inode-based
watch would not; a real investigation adds a probe on the resolved path
(`kprobe:vfs_open`, `kfunc`s) once the simple one has come up empty.

## Reading what it catches

```
$ bpftrace /root/watch.bt
Attaching 4 probes...
09:41:20 uid=999 comm=warm syscall=tracepoint:syscalls:sys_enter_openat
$ getent passwd 999
svc-cache:x:999:999::/home/svc-cache:/usr/sbin/nologin
$ systemctl status cache-warmer
```

Every ten seconds a service account, through a script called `warm`, opens the
file for writing. Its "cache warming" is a `sed` that rewrites `max_refund`.
alice's `vi` session was real and is irrelevant.

## Checking yourself

Run the watch, and in another shell do each of the grader's moves yourself:
`cat` the file (nothing), `sed -i` it (one rename line), `echo >> ` it (one
openat line), write `/etc/pay/other` (nothing).

<details>
<summary>Solution</summary>

```
tracepoint:syscalls:sys_enter_openat
/ str(args->filename) == "/etc/pay/limits.conf" && (args->flags & 3) != 0 /
{
  printf("%s uid=%d comm=%s syscall=%s\n", strftime("%H:%M:%S", nsecs), uid, comm, probe);
}

tracepoint:syscalls:sys_enter_rename*
/ str(args->newname) == "/etc/pay/limits.conf" /
{
  printf("%s uid=%d comm=%s syscall=%s\n", strftime("%H:%M:%S", nsecs), uid, comm, probe);
}
```

```
user: svc-cache
process: warm
syscall: openat
```

</details>
