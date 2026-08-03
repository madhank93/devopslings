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
Archived and active journals take up 96.4M in the file system.
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

All four at once: the setting in effect, the bytes actually gone from the disk,
the history still readable, and the service still writing. Three of those are
easy to get individually and mutually destructive if you take the shortest path
to each.

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
<summary>Hint 3 — the setting does not delete anything</summary>

Restart journald with the new cap and look again:

```
$ journalctl --disk-usage
Archived and active journals take up 96.4M in the file system.
```

Unchanged. `SystemMaxUse=` governs what journald does **from now on** — it will
rotate and discard as it writes past the limit. It does not go back and reclaim
what is already there, so on a box that is nearly full it buys you nothing
today.

```
$ journalctl --vacuum-size=24M
$ journalctl --vacuum-time=7d
```

`--vacuum-size` removes archived journal files, oldest first, until the total is
under the size you name.

And the obvious trap: `--vacuum-size=1K` passes every size check and throws away
the history. Vacuum to something *under* your cap, not to nothing.

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
Vacuuming done, freed 72.1M of archived journals.

$ journalctl --disk-usage
Archived and active journals take up 23.8M in the file system.

$ journalctl -u order-events -n 5 -o cat
order-events: processed order ORD-018842 in 47ms
...
```

`SystemMaxFileSize=8M` is not required, and it is worth setting: without it a
single journal file can consume the entire allowance, and rotation then has
nothing smaller than "everything" to discard.

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

2. **A retention setting and a reclaim are separate actions.** The cap applies
   going forward; the vacuum handles the past. This same split appears in log
   rotation, in cloud storage lifecycle rules (module 17), and in Prometheus
   retention (module 18) — configure the policy, then reconcile what already
   exists, because the policy will not do it for you.

3. **"Under the limit" is not the goal.** `--vacuum-size=1K` satisfies every
   size check on the box and destroys the only record of what happened last
   night. Retention exists to retain something; a policy that keeps nothing has
   passed the check and failed the purpose. Whatever bounds the size should be
   paired with a statement of how far back you must be able to see.

</details>
