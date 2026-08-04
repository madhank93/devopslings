---
title: "the reindex that dies every time your laptop sleeps"
---

## The situation

The reindex takes about six hours. It has been started three times this week
and finished none of them — each run ended when the SSH session did.

```
$ ssh box
$ /usr/local/bin/reindex &
[1] 4192
$ exit
```

Six hours later there is no index. The `&` was supposed to handle this. It does
not, and "close the laptop more carefully" is not a plan.

## Your objectives

| file | answer |
|---|---|
| `/root/answers/signal` | one of `sighup`, `sigint`, `sigterm`, `sigkill` |

Then start `/usr/local/bin/reindex` so that it **keeps running** when that
signal is delivered to it.

## What you're being graded on

The check finds your reindex process, confirms it is actually making progress,
sends it the signal, and then confirms it is *still* making progress
afterwards. Surviving while wedged does not count.

<details>
<summary>Hint 1 — what actually happens when the connection drops</summary>

The terminal disappears. The kernel notices that the controlling terminal for
that session is gone and sends **`SIGHUP`** — "hang up", named for the modem it
originally described — to the session leader, which is your shell. `bash` then
forwards `SIGHUP` to each of its jobs before exiting.

The others, for contrast:

| | sent by | when |
|---|---|---|
| `SIGINT` | the terminal driver | you press Ctrl-C |
| `SIGTERM` | `kill`, systemd | a polite request to shut down |
| `SIGKILL` | `kill -9`, the OOM killer | never negotiable, never catchable |

Note `SIGKILL` cannot be the answer to this exercise: nothing survives it, and
you are being asked to arrange survival.

The default action for `SIGHUP` is to terminate. `reindex` installs no handler,
so it dies.

</details>

<details>
<summary>Hint 2 — why `&` does not help</summary>

`&` puts the job in the **background of the same session**. Background is about
which job owns the terminal for input; it says nothing about session membership.
When the session is hung up, background jobs get the signal too.

Watch the structure:

```
$ ps -o pid,ppid,pgid,sess,tty,cmd -p $(pgrep -f '[/]usr/local/bin/reindex')
```

Three groupings, and they are not the same thing:

- **PGID** — a process group. What Ctrl-C targets.
- **SESS** — a session. What a terminal owns, and what gets hung up.
- **TTY** — the controlling terminal, or `?` for none.

A job started with `&` shares your SESS and your TTY. That is exactly the set
the hangup is delivered to.

</details>

<details>
<summary>Hint 3 — two ways out, and they work differently</summary>

**Ignore the signal.** `nohup` starts the command with `SIGHUP` set to
`SIG_IGN`. The signal is still delivered; the process is immune to it.

```
$ nohup /usr/local/bin/reindex > /var/log/reindex.log 2>&1 &
```

**Leave the session.** `setsid` runs the command in a brand new session with no
controlling terminal. There is no terminal whose loss could produce a hangup for
it — the signal is never sent in the first place.

```
$ setsid /usr/local/bin/reindex > /var/log/reindex.log 2>&1 < /dev/null &
```

Also worth knowing: `disown -h` marks an already-running job so bash will not
forward `SIGHUP` to it, which is what you reach for when the job is already
running and you forgot.

Redirect all three streams. A detached process whose stdout still points at a
vanished terminal will die on `SIGPIPE`, or block, the first time it writes —
which looks exactly like the problem you just fixed.

</details>

<details>
<summary>Solution</summary>

```
$ echo sighup > /root/answers/signal
$ setsid nohup /usr/local/bin/reindex > /var/log/reindex.log 2>&1 < /dev/null &
```

```
$ ps -o pid,pgid,sess,tty,cmd -p $(pgrep -f '[/]usr/local/bin/reindex')
    PID    PGID    SESS TTY      CMD
   4271    4271    4271 ?        /bin/bash /usr/local/bin/reindex

$ kill -HUP 4271
$ sleep 2; cat /srv/reindex/progress    # still climbing
```

Its own session, its own process group, no controlling terminal.

### Why this is a lesson at all

The instinct — `&`, then blame the network — treats a deterministic mechanism as
bad luck. Nothing here is flaky. The same signal arrives at the same processes
every time, for a documented reason, and the job was started in the one way that
guarantees receiving it.

Two ideas worth keeping:

1. **Backgrounding is not detaching.** `&` changes which job owns the terminal's
   input. It does not change session membership, and the session is the unit the
   hangup is delivered to. These get conflated constantly and the distinction is
   the whole exercise.

2. **Removing the cause beats ignoring the symptom.** `nohup` makes the process
   immune to a signal it still receives; `setsid` means the signal is never
   generated for it. Both pass. The second composes better — a process with no
   controlling terminal also cannot be stopped by terminal job control, and
   cannot block on a read from a terminal that is gone.

And the honest ending: for a six-hour job on a server, neither is really the
right answer. `systemd-run --unit=reindex /usr/local/bin/reindex` gets you a
unit with logs in the journal, a recorded exit status, and a life independent of
whoever started it. `tmux` and `screen` solve it by keeping a terminal alive to
own the session — same mechanism, viewed from the other end. Knowing *why* `&`
fails is what lets you pick between those instead of guessing.

</details>
