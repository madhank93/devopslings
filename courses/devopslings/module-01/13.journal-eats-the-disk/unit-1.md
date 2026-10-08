---
title: "a healthy service that takes the box down in three weeks"
---

## The situation

`order-events` is fine. It processes orders, it logs one line per order, it has
never crashed. Capacity planning has it running for years.

```
$ systemctl is-active order-events
active

$ journalctl --disk-usage
Archived and active journals take up 112.2M in the file system.
```

That number only goes up. Nothing rotates it, nothing caps it, and the box has
a small `/var`. There is no incident yet — there is an arithmetic problem with
a date on it.

This is the failure mode nobody gets paged for until the night it happens,
because every dashboard shows a healthy service right up to the moment the
filesystem is full and every service on the box starts failing at once.

## Your objectives

1. Cap the journal so it cannot grow past **48M**, and make the cap survive a
   restart of journald.
2. Bring the journal **already on disk** back under that cap.
3. Keep the recent history — the check reads back the last events
   `order-events` produced.

`order-events` must still be running and still logging when you are done.

## What you're being graded on

All at once: the setting in effect, the bytes actually gone from the disk, the
history still readable — `order-events` logged a settlement checkpoint just
before you took over, and the check looks for it — and the service still
writing. Then the check writes a burst of order events bigger than any sensible
cap and requires the journal to stay at the cap. Those are easy to get
individually and mutually destructive if you take the shortest path to each.

<details>
<summary>Hint 1 — what the default actually is</summary>

```
$ man 5 journald.conf
```

`SystemMaxUse=` bounds the persistent journal under `/var/log/journal`. Unset,
journald defaults to **10% of the filesystem, capped at 4G** — a number derived
from the disk rather than from what you need, which on a large disk is many
gigabytes of order events nobody will ever read.

Related knobs worth knowing:

| | |
|---|---|
| `SystemMaxUse=` | total the persistent journal may occupy |
| `SystemKeepFree=` | leave at least this much free, whatever else it wants |
| `SystemMaxFileSize=` | size of an individual journal file before it rotates |
| `MaxRetentionSec=` | discard entries older than this, regardless of size |

`SystemMaxUse` and `MaxRetentionSec` answer two different questions — "how much
disk can I afford" and "how far back do I need to see". Real policies usually
set both.

</details>

<details>
<summary>Hint 2 — where to put it, and why not in journald.conf</summary>

You can edit `/etc/systemd/journald.conf`, and a package upgrade can replace
that file and take your change with it. Use a drop-in:

```
$ install -d /etc/systemd/journald.conf.d
$ cat > /etc/systemd/journald.conf.d/size.conf <<'CONF'
[Journal]
SystemMaxUse=32M
CONF
$ systemctl restart systemd-journald
```

Confirm what is actually in effect, rather than what you think you wrote —
drop-ins merge, and the last one wins:

```
$ systemd-analyze cat-config systemd/journald.conf | grep -i systemmaxuse
```

</details>

<details>
<summary>Hint 3 — a cap in a file is not a cap</summary>

Write the drop-in and look again, before restarting anything:

```
$ journalctl --disk-usage
Archived and active journals take up 112.2M in the file system.
```

Unchanged: journald read its configuration when it started and has not read it
since. Restart it and journald applies the new limit straight away — it
deletes archived journal files, oldest first, until the total is under
`SystemMaxUse=`, and from then on it does the same at every rotation.

```
$ systemctl restart systemd-journald
$ journalctl --disk-usage
Archived and active journals take up 28.4M in the file system.
```

It only ever removes *archived* files; the active `system.journal` is never
vacuumed. To trim further without waiting for a rotation, vacuum by hand:

```
$ journalctl --vacuum-size=24M
$ journalctl --vacuum-time=7d
```

And the obvious trap: `--vacuum-size=1K` (or `rm` in `/var/log/journal`)
passes every size check and throws away the history. Vacuum to something
*under* your cap, not to nothing.

</details>

<details>
<summary>Solution</summary>

```
$ install -d /etc/systemd/journald.conf.d
$ cat > /etc/systemd/journald.conf.d/size.conf <<'CONF'
[Journal]
SystemMaxUse=32M
SystemMaxFileSize=8M
CONF

$ systemctl restart systemd-journald
$ journalctl --vacuum-size=24M

$ journalctl --disk-usage
Archived and active journals take up 23.8M in the file system.

$ journalctl -u order-events -n 5 -o cat
order-events: processed order ORD-018842 in 47ms
...
```

`SystemMaxFileSize=8M` is not required — journald defaults it to an eighth of
`SystemMaxUse=` — but writing it down makes the unit of deletion explicit:
vacuuming removes whole archived files, so this is the granularity at which
history disappears.

### Why this is a lesson at all

Nothing here is broken, which is what makes it hard to see. `disk-full-triage`
gave you a filesystem already full and a process holding the space. This one is
a service behaving perfectly, logging exactly what it was asked to log, on a
box where nobody ever said how much of that to keep. The bug is an absent
decision.

Three things worth keeping:

1. **Unbounded growth is a bug with a date, not a state.** Anything that
   accumulates — journals, application logs, caches, uploads, database WAL,
   Docker images — is an incident scheduled for whenever the divisor runs out.
   The dashboard is green for the entire run-up, and then every service on the
   box fails simultaneously for a reason unrelated to any of them.

2. **A policy on disk is not a policy in force.** The cap did nothing until
   journald re-read it; the restart is what reconciled the files already
   there. Check what the running daemon reports (`journalctl -u
   systemd-journald` prints "max …" on every start), not what the file says.
   Other systems split this further — log rotation, cloud storage lifecycle
   rules (module 17) and Prometheus retention (module 18) each have their own
   rule for what already exists — so find out which one you are dealing with.

3. **"Under the limit" is not the goal.** `--vacuum-size=1K` satisfies every
   size check on the box and destroys the only record of what happened last
   night. Retention exists to retain something; a policy that keeps nothing has
   passed the check and failed the purpose. Whatever bounds the size should be
   paired with a statement of how far back you must be able to see.

</details>
