---
title: "The disk is full but du says it isn't"
---

## The situation

It's 02:10. The alert says `/var/log/app` is above 90% on `box`. You SSH in,
and this is what you get:

```
$ df -h /var/log/app
Filesystem      Size  Used Avail Use% Mounted on
tmpfs            64M   58M  6.0M  91% /var/log/app

$ du -sh /var/log/app
12K     /var/log/app
```

58 megabytes used. Twelve kilobytes of files. Those numbers cannot both be
right, and yet they are.

The obvious move is to delete something. Try it — it won't help, and `du` has
already told you why: there is nothing there to delete.

## Your objectives

1. Work out where the 58 MB actually lives.
2. Give the space back, without deleting the real log files.
3. Make sure it stays given back.

Objective 3 is the one that catches people. There is a version of this fix that
works for about two seconds.

## What you're being graded on

The check looks at four things: that the space came back, that nothing is still
holding it, that you addressed the cause rather than the process, and that
`app.log` and `access.log` are still there.

<details>
<summary>Hint 1 — df and du measure different things</summary>

`du` walks directory entries and adds up the files it can see. `df` asks the
filesystem how many blocks are allocated.

A file's blocks are freed when two conditions are both met: no directory entry
points at it, **and** no process has it open. Unlink a file that a process is
still holding, and you get exactly this — allocated blocks that no name points
to. `du` cannot see them because there is nothing left to walk.

</details>

<details>
<summary>Hint 2 — how to see files that no longer have names</summary>

`lsof` has a flag for precisely this:

```
lsof -nP +L1
```

`+L1` means "files with a link count below 1" — open, but unlinked. The `NLINK`
column will read `0`. That tells you the PID, the size, and the mount.

Without `lsof` you can do the same thing by hand:

```
ls -l /proc/*/fd 2>/dev/null | grep deleted
```

</details>

<details>
<summary>Hint 3 — you fixed it and it came back</summary>

Look at what started the process:

```
systemctl status log-exporter.service
```

`Restart=always`. Killing the PID gets you two seconds of free space and then
systemd starts it again, and it does the same thing on startup.

The fd closes when the process exits — you don't need to do anything to the
file. You need the process to stop, and to stay stopped.

</details>

<details>
<summary>Solution</summary>

Find who's holding the space:

```
$ lsof -nP +L1
COMMAND   PID USER   FD   TYPE DEVICE   SIZE/OFF NLINK    NODE NAME
python3   142 root    3w   REG   0,52   60817408     0     19 /var/log/app/export.tmp (deleted)
```

PID 142, 58 MB, link count 0, and the name ends in `(deleted)`. The file was
unlinked while still open.

Find out what that process belongs to:

```
$ systemctl status log-exporter.service
● log-exporter.service - Nightly report exporter
     Active: active (running)
   Main PID: 142 (log-exporter)
```

Stop the unit — not the process:

```
systemctl stop log-exporter.service
systemctl disable log-exporter.service
```

```
$ df -h /var/log/app
Filesystem      Size  Used Avail Use% Mounted on
tmpfs            64M   12K   64M   1% /var/log/app
```

### What actually happened

`log-exporter` writes a 58 MB scratch file, calls `unlink()` on it to "clean
up", and then sleeps — holding the descriptor for the whole time. The kernel
cannot reclaim the blocks until the last descriptor closes, so the space stays
gone and `du` cannot account for it.

This is not a contrived bug. It is one of the most common causes of a full disk
in production, and it shows up most often with log files that were rotated out
from under a process that never reopened them. Rotate `app.log` while something
holds it open and you get this exact shape — which is why `logrotate` has a
`copytruncate` option and why so many daemons handle `SIGHUP`.

### Doing it properly

Stopping the unit is the right call at 02:10. The real fix is in the exporter:
it should write to a named temp file and unlink it *after* closing, or use the
scratch file without deleting it until the work is done. Getting the space back
is incident response; getting the code fixed is the follow-up ticket.

</details>
