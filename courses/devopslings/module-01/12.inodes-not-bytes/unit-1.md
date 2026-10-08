---
title: "no space left on device, and 57M free"
---

## The situation

checkout-api started failing an hour ago. Every write to `/srv/spool` returns
the same thing:

```
[error] failed to write session: open /srv/spool/sessions/sess-a91f: no space left on device
```

So you check, and the filesystem is nearly empty:

```
$ df -h /srv/spool
Filesystem      Size  Used Avail Use% Mounted on
tmpfs            64M  7.9M   57M  13% /srv/spool
```

13% used. 57M available. `ENOSPC` anyway, and there is no large file to hunt
for this time.

## Your objectives

Get `/srv/spool` writable again, and make sure tonight's run does not put you
back here.

- `/srv/spool/payload/` must survive intact — it is the settlement batch.
- `session-reaper.service` runs nightly and must actually reclaim the resource
  that is being consumed. The check seeds fresh stale sessions and runs it.
- Session files younger than a day are live sessions. Deleting those logs
  people out.

## What you're being graded on

`/srv/spool` back under 50% on whatever actually ran out — on the filesystem
as it was made, not remounted bigger — the payload byte-for-byte intact,
writes working —
and then the recurrence: the check creates 400 stale and 40 live session files,
runs the reaper, and requires that all 400 go and all 40 stay.

<details>
<summary>Hint 1 — a filesystem has two things it can run out of</summary>

```
$ df -h /srv/spool     # bytes
$ df -i /srv/spool     # inodes
```

Every file, directory, symlink and socket consumes one **inode**, regardless of
its size. A zero-byte file costs one inode and no data blocks at all. On ext4 the
inode table is sized when the filesystem is made and cannot be grown
afterwards.

So a filesystem holding two thousand tiny files is completely full while being
nearly empty. `ENOSPC` is the same errno for both conditions, which is why
the error message sends everyone to `df -h` and then to a dead end.

```
$ df -i /srv/spool
Filesystem     Inodes IUsed IFree IUse% Mounted on
tmpfs            2000  2000     0  100% /srv/spool
```

</details>

<details>
<summary>Hint 2 — find where the entries went, not where the bytes went</summary>

`du -sh` measures size, so it ranks a directory of two thousand tiny files
below a single 10 MB log. Count entries instead:

```
$ for d in /srv/spool/*/; do printf '%8d  %s\n' "$(find "$d" | wc -l)" "$d"; done
      13  /srv/spool/payload/
    1986  /srv/spool/sessions/
```

Then look at what they actually are:

```
$ ls -l /srv/spool/sessions | head -3
$ find /srv/spool/sessions -type f -mtime +1 | wc -l
```

Three days of session files that nothing removed, a few bytes each.

**Do not** reach for `rm -rf /srv/spool/*`. That frees every inode and takes the
settlement batch with it. The check verifies the payload by checksum.

</details>

<details>
<summary>Hint 3 — why the nightly cleanup never cleaned anything</summary>

There is already a job for this and it has run every night for two years:

```
$ cat /usr/local/bin/session-reaper
find /srv/spool/sessions -type f -size +1M -delete
```

`-size +1M`. It was written during a disk-full incident, when the problem was
genuinely large files, and it has been correct for that problem ever since.

A session file is a few bytes. This job has never matched a single one, and
never will. It exits 0 every night, which is exactly why nobody noticed: the
cleanup is *running*, it is *succeeding*, and it is reclaiming nothing.

Prune on the axis that actually runs out. Here that is age:

```
find /srv/spool/sessions -type f -mtime +1 -delete
```

</details>

<details>
<summary>Solution</summary>

```
$ df -i /srv/spool
Filesystem     Inodes IUsed IFree IUse% Mounted on
tmpfs            2000  2000     0  100% /srv/spool

$ find /srv/spool/sessions -type f -mtime +1 -delete

$ df -i /srv/spool
Filesystem     Inodes IUsed IFree IUse% Mounted on
tmpfs            2000    15  1985    1% /srv/spool
```

And the recurrence:

```bash
#!/bin/bash
set -euo pipefail
# Sessions are a few bytes each, so size is meaningless here — what exhausts
# this filesystem is the number of entries. Age is the axis that matters.
find /srv/spool/sessions -type f -mtime +1 -delete
echo "session-reaper: done"
```

### Why this is a lesson at all

`disk-full-triage` earlier in this module was a filesystem that was genuinely
full of bytes you could not see. This is the opposite: a filesystem with
almost no bytes in it that cannot accept another file. Both report `ENOSPC`, and
the reflex both trigger — look for the big file — is right in one case and a
dead end in the other.

Three things worth keeping:

1. **`ENOSPC` is two errors sharing one errno.** Check `df -i` alongside `df
   -h`, always, and it costs one command. The signature here is unmistakable
   once you have seen it: bytes to spare, 100% inodes. Mail spools, session stores,
   cache directories and anything that writes one small file per event are the
   usual candidates.

2. **A cleanup job that exits 0 is not evidence it cleaned anything.** The
   reaper succeeded every night for two years while reclaiming nothing. It was
   written for a real incident and stayed correct for that incident forever
   after — this is the same failure as `package-held-back` earlier in the
   module, where `apt` also exited 0 while not doing the thing anyone believed
   it was doing. If a job exists to reclaim a resource, something should be
   asserting the resource actually went down.

3. **Prune on the axis that is scarce.** Size, age and count are three
   different policies. Choosing the wrong one gives you a job that looks
   thorough in review, runs forever, and does nothing — and the wrongness is
   invisible until the resource it ignores runs out.

</details>
