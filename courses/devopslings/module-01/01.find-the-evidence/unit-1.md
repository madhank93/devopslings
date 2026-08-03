---
title: "the log file is empty and the answer is somewhere else"
---

## The situation

`invoice-sync` runs at 03:00. This morning it did not sync anything, and the
first place anyone looked was the obvious one:

```
$ ls -l /var/log/invoice-sync/
total 4
-rw-r--r-- 1 root root   0 Aug  3 03:00 app.log
-rw-r--r-- 1 root root 108 Aug  3 03:00 access.log

$ cat /var/log/invoice-sync/app.log
$
```

Zero bytes. The natural conclusion — "it never ran, or it never logged
anything" — is wrong on both counts. It ran, it failed, and it said why. Just
not there.

## Your objectives

Two files, each containing one thing and nothing else:

| file | answer |
|---|---|
| `/root/answers/where` | one of `journal`, `dmesg`, `logfile`, `fd` |
| `/root/answers/line` | the message that says why it failed, copied out |

The four candidates, and what each is actually for:

| | holds |
|---|---|
| `journal` | whatever a systemd unit wrote to stdout and stderr, plus systemd's own record of it |
| `dmesg` | the kernel ring buffer — what the *kernel* did to a process, or to hardware |
| `logfile` | files under `/var/log` that an application wrote itself |
| `fd` | what a **running** process currently has open, via `/proc/<pid>/fd` |

## What you're being graded on

Naming the right one of the four, and producing the message. Extra text around
the message — a journal timestamp, the hostname — is fine; the check looks for
the message inside whatever you paste.

<details>
<summary>Hint 1 — an empty log file is a fact, not an absence</summary>

The file exists and is zero bytes. Those are two separate pieces of
information:

- **It exists**, so the process got far enough to create or open it. Something
  ran.
- **It is empty**, so the process died before it wrote a single line to it.

That narrows the failure to *early* — configuration, permissions, arguments —
before the application reached the point where its own logging was doing any
work. Which is exactly the window in which a program's complaints go to stderr
instead, because that is all it has.

</details>

<details>
<summary>Hint 2 — where does a systemd service's stderr go?</summary>

Nowhere you have to configure. systemd connects every unit's stdout and stderr
to the journal by default, so anything the process printed is recorded even
though the application never opened a log file for it.

```
$ systemctl status invoice-sync.service
$ journalctl -u invoice-sync.service --no-pager
```

`-u` scopes to one unit. Add `-b` for this boot only, `-e` to jump to the end,
`-o cat` to strip the timestamp and hostname and show only what the process
itself printed.

</details>

<details>
<summary>Hint 3 — ruling the other three out is the actual skill</summary>

Do not just find the answer; know why the other three were wrong. That is what
makes this fast next time.

**`dmesg`** — the kernel's ring buffer. It has something to say when the
*kernel* acted on your process: an OOM kill, a segfault, an I/O error, a
filesystem going read-only. Here the process chose to exit, so the kernel has
no opinion.

```
$ dmesg | tail -20
```

**`logfile`** — application-written files. `app.log` is empty and `access.log`
is health checks. Worth ten seconds, and then move on.

**`fd`** — `/proc/<pid>/fd` shows what a **live** process has open, which is
how you find out where a running daemon is actually writing when it is not
where you expected. It needs a PID that still exists. This process died an hour
ago.

```
$ ls -l /proc/<pid>/fd     # for something still running
```

</details>

<details>
<summary>Solution</summary>

```
$ journalctl -u invoice-sync.service --no-pager -o cat
FATAL: /etc/invoice-sync/rules.conf line 12: unexpected "}" — no rules loaded

$ echo journal > /root/answers/where
$ journalctl -u invoice-sync.service --no-pager -o cat | grep FATAL > /root/answers/line
```

And the cause is right where the message says it is:

```
$ sed -n '10,13p' /etc/invoice-sync/rules.conf
  match {
    vendor  = "initech"
    account = "4300"
  }}
```

A doubled closing brace. The program told you the file, the line number and the
character. It just told you somewhere nobody looked.

### Why this is a lesson at all

Every other exercise in this module assumes you can find out what happened.
This one is that assumption, made explicit, because the wrong instinct here
costs more time than any other single mistake in operations: **concluding from
an empty log that there is nothing to find.**

Four places, four different questions:

1. **The journal** — "what did this unit say?" First stop for anything systemd
   started, and it captures stderr from processes that have no logging
   configuration at all. Most startup failures live here and nowhere else.
2. **`dmesg`** — "what did the kernel do to it?" OOM kills, segfaults, I/O
   errors. If a process vanished with no message of its own, this is where the
   record is (module 01's `oom-killed` is exactly that case).
3. **Files under `/var/log`** — "what did the application choose to write?"
   Only as good as the application's own logging, and useless for failures that
   happen before logging is up.
4. **`/proc/<pid>/fd`** — "where is this *running* process actually writing?"
   The one that answers questions the other three cannot, and the one that
   needs a live process. Requires you to look *before* you restart anything —
   the same discipline `blocked-on-a-pipe` is built on.

Check them in that order and the median incident gets shorter, because the
first one is right most of the time and costs one command.

</details>
