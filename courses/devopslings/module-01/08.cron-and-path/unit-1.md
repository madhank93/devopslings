---
title: "the backup runs fine when you run it and writes nothing at 03:17"
---

## The situation

`checkout` is backed up nightly by a cron job at 03:17. The last file in
`/var/backups/checkout` is three weeks old.

```
$ ls -lt /var/backups/checkout
-rw-r--r-- 1 root root 217 Jul 12 03:17 checkout-20260712T031702.tar.gz
```

The person who wrote it has already checked the obvious thing:

```
$ /usr/local/bin/nightly-backup.sh
[2026-08-02T09:12:44+00:00] nightly-backup starting
snapshot: wrote /var/backups/checkout/checkout-20260802T091244.tar.gz (231 bytes)
[2026-08-02T09:12:44+00:00] nightly-backup finished
```

It works. It has always worked. It works every single time a human runs it,
and it has not produced a file on its own since July 12. There is no error
anywhere they have thought to look: `/var/log/nightly-backup-<date>.log` does
not exist, and nothing has been mailed to anyone.

`cron` is running, the crontab is there, and cron has attempted the job — this
box replays the attempt on startup so you have a real record to read rather
than a story about one.

## Your objectives

1. Find out what cron actually ran last night, and why it produced nothing.
2. Make the job work when cron runs it — not when you run it.
3. Make sure the next failure leaves a message somewhere a human will read.

Leave the schedule at `17 3 * * *`. The check runs the job for you, through
the real cron, on a schedule it controls; changing when it fires is not the
fix and will fail the check.

## What you're being graded on

That cron — not your shell — produces a fresh, valid backup in
`/var/backups/checkout`, and that the run leaves output in a dated
`/var/log/nightly-backup-<date>.log`. The check wipes both first, so a backup
you made by hand does not count.

<details>
<summary>Hint 1 — cron keeps a record of what it ran</summary>

The job's own log is missing, but cron logs every job it starts:

```
journalctl -u cron.service --since '-1 hour' --no-pager
```

Two things in there are worth staring at. The `CMD (...)` line shows the
command cron handed to the shell. Compare it, character by character, with the
line in `crontab -l`. And somewhere near it:

```
(CRON) info (No MTA installed, discarding output)
```

That is where the error message went. cron mails a job's output to the owner;
this box has no mail transport, so anything the job said was thrown away.

</details>

<details>
<summary>Hint 2 — the crontab is not a shell script</summary>

`crontab(5)`:

> The "sixth" field (the rest of the line) specifies the command to be run.
> [...] Percent-signs (%) in the command, unless escaped with backslash (\),
> will be changed into newline characters, and all data after the first % will
> be sent to the command as standard input.

Now read the line again:

```
17 3 * * * /usr/local/bin/nightly-backup.sh >> /var/log/nightly-backup-$(date +%Y-%m-%d).log 2>&1
```

`date +%Y-%m-%d` is a perfectly good shell command. It is not a good crontab
command.

</details>

<details>
<summary>Hint 3 — cron's environment is not your environment</summary>

Once the command survives cron's parser, it runs — and hits the second bug.
cron does not read `/etc/profile`, `~/.bash_profile` or `~/.bashrc`. It gives
a job a nearly empty environment:

```
SHELL=/bin/sh
PATH=/usr/bin:/bin
HOME=/root
LOGNAME=root
```

Note what is not in that `PATH`. Then:

```
$ command -v snapshot
/opt/backup/bin/snapshot
$ grep -r backup-tools /etc/profile.d/
```

You can reproduce cron's view of the world without waiting for 03:17:

```
env -i SHELL=/bin/sh PATH=/usr/bin:/bin HOME=/root LOGNAME=root \
  /bin/sh -c /usr/local/bin/nightly-backup.sh
```

There is more than one place to fix this. One of them fixes it for cron only;
another fixes it for anything that ever starts the script.

</details>

<details>
<summary>Solution</summary>

### 1. What cron ran

```
$ journalctl -u cron.service --since '-1 hour' --no-pager
Aug 02 09:27:01 box CRON[353]: pam_unix(cron:session): session opened for user root(uid=0) by (uid=0)
Aug 02 09:27:01 box CRON[355]: (root) CMD (/usr/local/bin/nightly-backup.sh >> /var/log/nightly-backup-$(date +)
Aug 02 09:27:01 box CRON[353]: (CRON) info (No MTA installed, discarding output)
Aug 02 09:27:01 box CRON[353]: pam_unix(cron:session): session closed for user root
```

The command stops at `+%`. cron turns an unescaped `%` into a newline and
feeds everything after it to the command as stdin, so the shell received:

```
/usr/local/bin/nightly-backup.sh >> /var/log/nightly-backup-$(date +
```

— an unterminated `$(`. The shell failed to parse it and never ran anything,
which is why there is no backup *and* no log: the redirection that was
supposed to create the log is part of the line that did not survive.

The error went to root's mail. There is no MTA, so it went nowhere.

### 2. Escape the percent signs

```
$ crontab -e
17 3 * * * /usr/local/bin/nightly-backup.sh >> /var/log/nightly-backup-$(date +\%Y-\%m-\%d).log 2>&1
```

Run it the way cron will and the next bug appears — this time in the log,
because the redirection now works:

```
$ cat /var/log/nightly-backup-2026-08-02.log
[2026-08-02T09:30:01+00:00] nightly-backup starting
/usr/local/bin/nightly-backup.sh: line 6: snapshot: command not found
```

### 3. Give the script its own PATH

`snapshot` is in `/opt/backup/bin`, which reaches your `PATH` through
`/etc/profile.d/backup-tools.sh`. cron reads no profile, so its `PATH` is
`/usr/bin:/bin` and `snapshot` does not exist as far as the job is concerned.

```bash
#!/bin/bash
set -euo pipefail

# Do not inherit a PATH from whoever started us.
export PATH=/opt/backup/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

echo "[$(date -Is)] nightly-backup starting"
snapshot /srv/checkout /var/backups/checkout
echo "[$(date -Is)] nightly-backup finished"
```

```
$ cat /var/log/nightly-backup-2026-08-02.log
[2026-08-02T09:34:01+00:00] nightly-backup starting
snapshot: wrote /var/backups/checkout/checkout-20260802T093401.tar.gz (231 bytes)
[2026-08-02T09:34:01+00:00] nightly-backup finished
```

### Where to put the PATH fix

Three places work, and they are not equivalent:

**`PATH=...` at the top of the crontab.** Correct, one line, and it fixes only
this scheduler. The day the job moves to a systemd timer, a CI runner or a
container entrypoint, it breaks again in exactly the same way.

**Absolute path to `snapshot` in the script.** Correct and explicit. Fine for
one tool; tedious for a script that calls six.

**`export PATH=...` inside the script** — used above. The script stops
depending on who started it, which is the property you actually want: a script
that assumes an interactive login is a script that only works while you are
watching it.

### Why "it works when I run it" was never evidence

Your shell had `/opt/backup/bin` on `PATH` because a login shell reads
`/etc/profile.d/*` and an interactive one reads `/etc/bash.bashrc`. cron runs
`/bin/sh -c`, non-login and non-interactive: no profile, no rc file, four
environment variables, no terminal.

So a job that a person can run is not a job that cron can run. The three
things that differ, in the order they bite:

| | your shell | cron |
|---|---|---|
| shell | `bash`, interactive | `/bin/sh -c`, not interactive |
| `PATH` | everything profile.d added | `/usr/bin:/bin` |
| stdout/stderr | your terminal | mail, then `/dev/null` |

The last row is the one that turned a five-minute bug into three weeks of
silence. Anything scheduled should redirect its own output to a file it owns —
`>> /var/log/thing.log 2>&1` — rather than trusting that someone reads root's
mail. Nobody reads root's mail.

</details>
