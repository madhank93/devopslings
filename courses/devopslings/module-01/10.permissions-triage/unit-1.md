---
title: "the service cannot write to its own directory"
---

## The situation

`report-writer.service` produces a CSV into `/srv/reports`. A second account,
`publisher`, picks those files up and ships them. Both accounts are in the
`reports` group. This worked until someone rebuilt the directory last night.

```
$ systemctl status report-writer.service
× report-writer.service - Report writer
     Loaded: loaded (/etc/systemd/system/report-writer.service; enabled)
     Active: failed (Result: exit-code)

$ ls -l /srv/reports
total 8
-rw-r----- 1 svc-report reports 38 Aug  1 03:00 report-20260801T0300.csv
-rw-r----- 1 svc-report reports 38 Aug  2 03:00 report-20260802T0300.csv
```

The two files that are already there show you exactly what a correct report
looks like: owned by `svc-report`, group `reports`, mode `0640`. The service
that produced them can no longer produce another one.

Membership is not the problem, and it is worth ruling out first so you stop
looking at it:

```
$ id svc-report
uid=999(svc-report) gid=999(svc-report) groups=999(svc-report),1001(reports)
```

## Your objective

Make `report-writer.service` produce reports again, such that each **new** file
lands owned by `svc-report`, group `reports`, and readable by `publisher`.

Nothing under `/srv/reports` may be world-writable when you are done.

## What you're being graded on

The check does not look at the files that are there now. It starts the service,
waits for a **new** file, and inspects that one — its owner, its group, its
mode, and whether `publisher` can actually read it.

That matters because most of the ways to make the current error disappear do
not survive the creation of the next file.

<details>
<summary>Hint 1 — separate "cannot create" from "created wrong"</summary>

There are two questions here and they have different answers. Do not merge
them.

**Can the service create a file at all?** That is decided by the directory's
mode:

```
$ ls -ld /srv/reports
drwxr-xr-x 2 root reports 4096 Aug  3 00:12 /srv/reports
```

`svc-report` is in `reports`. The group triad is `r-x`. Creating a file in a
directory requires **write** on that directory — you are modifying the
directory itself, not the file.

**Once it can create a file, is the file right?** That is a different
mechanism, and fixing the first will show it to you.

</details>

<details>
<summary>Hint 2 — try the obvious fix, then look at what it produced</summary>

```
$ chmod 777 /srv/reports
$ systemctl start report-writer.service
$ ls -l /srv/reports
-rw------- 1 svc-report svc-report 44 Aug  3 00:20 report-20260803T0020.4821.csv
```

The error is gone. Now compare that line to the two files above it.

Group is `svc-report`, not `reports`. Mode is `0600`, not `0640`. `publisher`
cannot read it — and could not read it even if the group were right, because
there are no group bits at all.

Two separate things are wrong, and `chmod 777` on the directory addressed
neither. It only removed the symptom you happened to be looking at, while
granting every account on the box write access to the reports.

Undo it before you continue:

```
$ chmod 755 /srv/reports
```

</details>

<details>
<summary>Hint 3 — where a new file's group comes from</summary>

By default, a newly created file gets the **primary group of the process that
created it**. `svc-report`'s primary group is `svc-report`, so that is what its
files get — regardless of what group owns the directory they land in.

The setgid bit on a *directory* changes that rule: entries created inside it
inherit the directory's group instead.

```
$ chmod g+s /srv/reports
$ ls -ld /srv/reports
drwxr-sr-x 2 root reports 4096 ... /srv/reports
                ^
```

Note this is a completely different behaviour from setgid on an executable
file, where it changes the process's effective group. Same bit, two unrelated
meanings, depending on what it is set on.

</details>

<details>
<summary>Hint 4 — where a new file's mode comes from</summary>

The group is now right and `publisher` still cannot read the file. Look at the
unit:

```
$ systemctl cat report-writer.service | grep -i umask
UMask=0077
```

A umask is a mask of bits to **remove** at creation time. `0077` clears every
group and other bit, so the file arrives as `0600` no matter what the directory
says. The setgid bit put the right group on a file that gives that group no
access.

`0027` clears group-write and everything for other, leaving `0640` — which is
what the two existing reports are.

Override it without editing the shipped unit:

```
$ systemctl edit report-writer.service
```

or write the drop-in directly under
`/etc/systemd/system/report-writer.service.d/`, then `daemon-reload`.

</details>

<details>
<summary>Solution</summary>

### The directory

```
$ chgrp reports /srv/reports
$ chmod 2775 /srv/reports
$ ls -ld /srv/reports
drwxrwsr-x 2 root reports 4096 Aug  3 00:31 /srv/reports
```

`2775` is three decisions:

- **`g+w`** — members of `reports` can create files. This is what stops the
  unit failing.
- **`g+s`** — new entries inherit group `reports` instead of the creator's
  primary group. This is what makes them readable by `publisher` at all.
- **`o=rx`** — everyone else can traverse and list, and cannot write. This is
  the part `777` gave away.

### The umask

```
$ mkdir -p /etc/systemd/system/report-writer.service.d
$ cat > /etc/systemd/system/report-writer.service.d/umask.conf <<'CONF'
[Service]
UMask=0027
CONF
$ systemctl daemon-reload
```

### Result

```
$ systemctl start report-writer.service
$ ls -l /srv/reports
-rw-r----- 1 svc-report reports 38 Aug  1 03:00 report-20260801T0300.csv
-rw-r----- 1 svc-report reports 38 Aug  2 03:00 report-20260802T0300.csv
-rw-r----- 1 svc-report reports 44 Aug  3 00:33 report-20260803T0033.9134.csv
```

The new file is indistinguishable from the two that were already correct.

### Why this is a lesson at all

`chmod 777` is the single most common "fix" in this whole subject, and it is
worth being precise about why it is bad — not "because it is insecure", which
is true but is the argument people have learned to skip past.

**It is bad because it does not answer the question.** The question was "which
principals need which access to this data". `777` replaces that question with
"everyone gets everything", and in doing so it hides the fact that you never
found out what the actual failure was. Here, the failure was *two* things, and
`777` masked one of them while appearing to fix the other. The next file
created would have been wrong either way — it just would not have been wrong
until the publisher ran, hours later, with no obvious connection back to the
change you made.

The three mechanisms this lesson separates:

1. **Directory write permission** controls whether you can create, rename or
   delete an entry. It has nothing to do with the contents of the files
   inside — a file you cannot write can still be deleted if you can write the
   directory it is in.
2. **The setgid bit on a directory** controls what group new entries inherit.
   It is the only reasonable way to make a shared directory work between
   accounts with different primary groups, and it is invisible in `ls -l`
   unless you know to look for the `s` where the group `x` goes.
3. **The umask** controls the mode a process gives to files it creates. It
   belongs to the process, not the filesystem, which is why it is set in the
   unit and why no amount of `chmod` on the directory will change what the
   service produces tomorrow.

The general shape — *the thing you can see is wrong, and the thing that will be
wrong next time, are set by different mechanisms* — is the whole reason this
module exists.

</details>
