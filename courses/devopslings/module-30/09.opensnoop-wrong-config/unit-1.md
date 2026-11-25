---
title: "the config was changed, the service restarted, and nothing changed"
---

## The situation

Support asked for the greeter to greet in French. Someone made the change:

```
$ cat /etc/greeter/greeter.conf
# greeter settings
# 2026-11-20 support ticket 4411: greet in French
greeting = bonjour
$ systemctl restart greeter
$ curl 127.0.0.1:8090/
hello
```

Two restarts later it still says `hello`. The first guess is that the edit is
wrong — a typo in the key, a stray space, the wrong quote — so the file gets
edited again, and again. The file is fine. The question nobody has asked is
whether `greeter` ever opens it.

## Your objectives

- Find the config file `greeter` actually reads, from the files it opens
  while it starts
- Make `greeter` say `bonjour` after a restart, without changing its code
- Write `/root/answers/config.md` with the absolute path:

```
path: <the file greeter reads its greeting from>
```

## What you're being graded on

- `path` is the file `greeter` really reads, as an absolute path
- `/opt/greeter/greeter.py` is unchanged
- after the grader restarts `greeter`, `curl 127.0.0.1:8090/` says `bonjour`

<details>
<summary>Hint 1 — watch it start</summary>

A service reads its config once, at startup. Start the tracer first, then
restart the service in another shell:

```
opensnoop -n greeter
systemctl restart greeter
```

</details>

<details>
<summary>Hint 2 — the path is not quite the answer</summary>

The tracer prints the path the way the process passed it. If it does not
start with `/`, it is relative to the process's working directory:

```
ls -l /proc/$(pgrep -x greeter)/cwd
```

</details>

<details>
<summary>Hint 3 — two ways to fix it</summary>

Edit the file it reads, or remove the file that shadows the one you meant.
Either way, restart and `curl` again.

</details>

## Watching opens

Programs that look for a config file usually look in several places and take
the first one that exists. The order lives in the code, in a man page, or
nowhere written down at all. `opensnoop` skips the reading: it prints every
`open` as the kernel sees it, with the result.

```
$ opensnoop -n greeter
PID    COMM              FD ERR PATH
274933 greeter           -1   2
274933 greeter            3   0 greeter.conf
```

`-n` filters by process name. `PID` is the kernel's number for the process
in the *host* PID namespace; this container has its own, so for `/proc` here
use `pgrep -x greeter` instead. `FD` is the file descriptor the open returned,
or -1 on failure, with the errno in `ERR` (2 is `ENOENT`, "no such file").
The first line is an empty path — an environment variable `greeter` checks,
unset here — that fails. The second succeeds, and the search stops there:
`/etc/greeter/greeter.conf` is never tried.

`strace` shows the same thing from the system-call side and works without
BPF:

```
strace -f -e trace=openat -p $(pgrep -x greeter)    # attach, too late for startup
strace -f -e trace=openat -u greeter -o /tmp/g.trace /usr/bin/python3 /opt/greeter/greeter.py
```

Attaching to the running process is too late: the config was read at startup.
Running it under strace yourself works, as long as you run it the way systemd
does — as the same user, from the same directory. That last part matters.

`opensnoop` attaches to `syscalls:sys_enter_openat`. On kernels that deliver
the per-syscall tracepoints to BPF only for CPU 0 — Ubuntu's 7.0 kernels, for
one — it can miss an open that ran on another CPU. If the trace comes up
empty, restart once more, or use `strace`, which does not depend on BPF.

## The path the trace prints

`greeter.conf` with no directory is relative to the process's working
directory, which is whatever systemd set it to:

```
$ systemctl cat greeter | grep WorkingDirectory
WorkingDirectory=/opt/greeter
$ ls -l /proc/$(pgrep -x greeter)/cwd
lrwxrwxrwx 1 greeter greeter 0 ... /proc/4120/cwd -> /opt/greeter
$ cat /opt/greeter/greeter.conf
# defaults shipped with greeter 1.4
greeting = hello
port = 8090
```

A copy of the shipped defaults sits next to the program, and the program
looks in its working directory before `/etc`. Running `greeter.py` by hand
from `/root` would have read a different file again — which is why tracing the
service as systemd runs it beats reproducing it in a shell.

There are two fixes, and which is right depends on where the team wants the
setting to live. Edit `/opt/greeter/greeter.conf`, and the `/etc` file stays a
decoy for the next person. Or remove the stale copy, and the file everyone
already edits becomes the one that counts.

## Checking yourself

```
systemctl restart greeter && sleep 1 && curl 127.0.0.1:8090/
```

<details>
<summary>Solution</summary>

```
rm /opt/greeter/greeter.conf
systemctl restart greeter
curl 127.0.0.1:8090/      # bonjour
```

```
path: /opt/greeter/greeter.conf
```

</details>
