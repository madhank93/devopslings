---
title: "exit 1, and not one word about why"
---

## The situation

`ledger-export` dumps the day's ledger to a CSV that the upload job collects
from `/var/spool/ledger-export/out`. Since the box was rebuilt it fails every
night:

```
$ systemctl status ledger-export.service
× ledger-export.service - Nightly ledger export
     Active: failed (Result: exit-code)
    Process: 412 ExecStart=/usr/local/bin/ledger-export (code=exited, status=1/FAILURE)

$ journalctl -u ledger-export.service
systemd[1]: Starting ledger-export.service - Nightly ledger export...
systemd[1]: ledger-export.service: Main process exited, code=exited, status=1/FAILURE
```

systemd recorded that it failed. The tool said nothing at all: it catches its
own errors and exits 1. Module 01's `systemd-unit-failure` had a journal line
to read; this one has none. Someone has suggested `chmod -R 777` on every
directory it might touch, "to rule permissions out".

## Asking the kernel instead

A program cannot open a file, create a directory or connect a socket by
itself. It asks the kernel, through a system call, and the kernel answers
with a result or an error number. `strace` prints every one of those requests
and answers:

```
openat(AT_FDCWD, "/etc/ledger-export/export.conf", O_RDONLY|O_CLOEXEC) = 3
openat(AT_FDCWD, "/etc/ledger-export/export.local.conf", O_RDONLY|O_CLOEXEC) = -1 ENOENT (No such file or directory)
```

`= 3` is a file descriptor: it worked. `= -1 ENOENT` is a refusal, with the
errno name and its meaning. `EACCES` is "permission denied", `ENOENT` is "no
such file or directory".

Three things make the difference between a useful trace and a wall of text:

- **Trace it as the user it runs as.** The unit says `User=ledger`. Root is
  refused almost nothing, so a root trace of this tool can succeed. `strace -u
  ledger` runs the command as that user, as systemd does.
- **Follow children.** `-f` traces threads and child processes too; without
  it, a failure in a child is invisible.
- **Read from the end.** A Python program makes dozens of failed calls before
  it does anything: the interpreter probes its import path for every module
  and finds it on the third or fourth try. Those `ENOENT`s are normal. The
  failure that matters is the last refusal before `exit_group(1)`.

```
strace -f -u ledger -o /tmp/ledger.trace /usr/local/bin/ledger-export
grep -n -- '= -1 E' /tmp/ledger.trace | tail
```

## Your objectives

1. Write the refused call to `/root/answers/silent-exit.txt`:

   ```
   syscall=<the system call>
   errno=<the errno name>
   path=<the path it was refused on>
   ```

2. Fix the cause so that `systemctl start ledger-export.service` succeeds and
   the CSV lands in `/var/spool/ledger-export/out`.

## What you're being graded on

The check reads your answer, then runs the unit itself and counts the rows in
today's CSV. The tool must be unchanged and still run as `ledger`, and nothing
under `/etc/ledger-export`, `/var/lib/ledger-export` or
`/var/spool/ledger-export` may be world-writable.

<details>
<summary>Hint 1 — two ENOENTs that do not matter</summary>

The import-path probes, and `export.local.conf`: the tool tries the optional
override and carries on when it is missing. Both appear in a trace of a
successful run too. Compare what comes after them.

</details>

<details>
<summary>Hint 2 — what the refused call needs</summary>

Creating a file, and renaming one, are changes to the *directory*, not to the
file. Look at who owns `/var/spool/ledger-export/out` and what mode it has,
and what the `ledger` user would need to be allowed there.

</details>

<details>
<summary>Solution</summary>

The end of the trace:

```
openat(AT_FDCWD, "/var/spool/ledger-export/out/.ledger-2026-11-22.4711.tmp", O_WRONLY|O_CREAT|O_TRUNC|O_CLOEXEC, 0666) = -1 EACCES (Permission denied)
...
exit_group(1) = ?
```

```
syscall=openat
errno=EACCES
path=/var/spool/ledger-export/out
```

The spool directory was created by the packaging script as `root:root 0755`.
`ledger` can read it but not add entries to it. Give the directory to the user
that writes there, and nobody else:

```
chown ledger:ledger /var/spool/ledger-export/out
chmod 0750 /var/spool/ledger-export/out
```

`chmod 777` would have worked too, and made the directory a place any local
user can plant a file the upload job will ship as the ledger. Running the unit
as root would have worked for the same reason the root trace did: it removes
the check instead of answering it.

### strace in production

- strace stops the traced process on every system call. A busy service can
  slow by an order of magnitude under it. `-e trace=%file` or `-e
  trace=openat,connect` narrows what is printed, not what is stopped; for a
  hot process, the eBPF tools later in this module cost far less.
- `-p PID` attaches to a running process. `-T` adds the time spent in each
  call, `-c` a summary table; the next lesson uses both.

</details>
