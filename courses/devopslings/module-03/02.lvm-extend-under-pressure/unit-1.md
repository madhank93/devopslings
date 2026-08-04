---
title: "you added the disk, you grew the volume, and df has not moved"
---

## The situation

```
$ df -h /srv/data
Filesystem                 Size  Used Avail Use% Mounted on
/dev/mapper/datavg-datalv  253M  241M     0 100% /srv/data

$ journalctl -u ingest -n 2 -o cat
ingest: cannot write — no space
ingest: cannot write — no space
```

There is a spare physical volume sitting in the box, already prepared, not in
any volume group:

```
$ pvs
  PV         VG     Fmt  Attr PSize   PFree
  /dev/loop0 datavg lvm2 a--  316.00m  36.00m
  /dev/loop1        lvm2 ---  320.00m 320.00m
```

## Your objective

Grow `/srv/data` to at least **500M**, using that spare, without:

- deleting `/srv/data/ingest/backlog.bin` — the check verifies its checksum
- unmounting `/srv/data`
- restarting `ingest.service`

`ingest` must be writing again when you are done.

## What you're being graded on

Capacity as **`df`** reports it, the backlog intact, and `ingest` still running
as the same PID it had before you started. That last one is the point of using
LVM at all.

<details>
<summary>Hint 1 — three layers, and df only sees the top one</summary>

```
physical volume   /dev/loop0        the disk
volume group      datavg            the pool of disks
logical volume    datavg/datalv     the slice handed to a filesystem
filesystem        ext4 on datalv    what df measures
```

Four things, and growing capacity means moving space up through all of them.
Each has its own command and its own view:

```
$ pvs     # physical volumes, and how much of each is unallocated
$ vgs     # volume groups, and free space in the pool
$ lvs     # logical volumes, and their sizes
$ df -h   # filesystems, and what the application can actually use
```

Run all four now. Notice `vgs` reports 36M free while `df` reports 0 available.
Those are different questions about different layers.

</details>

<details>
<summary>Hint 2 — the first two steps, and the trap</summary>

```
$ vgextend datavg /dev/loop1        # the spare joins the pool
$ lvextend -l +100%FREE /dev/datavg/datalv
  Size of logical volume datavg/datalv changed from 280.00 MiB to 632.00 MiB.
  Logical volume datavg/datalv successfully resized.
```

Both succeeded. Now:

```
$ df -h /srv/data
/dev/mapper/datavg-datalv  253M  241M     0 100% /srv/data
```

Unchanged.

The logical volume really is 632M. The filesystem was created when the device
was 280M, and its superblock still describes a 280M filesystem. Nothing tells
it the device underneath grew, and it has no reason to go looking — a
filesystem that assumed spare space existed would be a filesystem that
corrupted itself on a device that shrank.

`-l +100%FREE` takes all free space in the group; `-L +220M` takes a fixed
amount. Either is fine here.

</details>

<details>
<summary>Hint 3 — the third step</summary>

```
$ resize2fs /dev/datavg/datalv
$ df -h /srv/data
/dev/mapper/datavg-datalv  613M  241M  343M  42% /srv/data
```

`resize2fs` grows ext4 **while it is mounted**. XFS uses `xfs_growfs` and takes
the mount point rather than the device. Btrfs uses `btrfs filesystem resize`.

Growing is online. **Shrinking is not** — it needs an unmount, and for XFS it is
not possible at all. That asymmetry is why "start small and grow" is sound
advice and "we can always shrink it later" usually is not.

In practice you would do the last two steps together:

```
$ lvextend -r -l +100%FREE /dev/datavg/datalv
```

`-r` resizes the filesystem too. It is separated here so the failure mode is
visible, because the failure mode is the whole lesson.

</details>

<details>
<summary>Solution</summary>

```
$ spare=$(pvs --noheadings -o pv_name,vg_name | awk '$2 == "" {print $1; exit}')
$ vgextend datavg "$spare"
$ lvextend -l +100%FREE /dev/datavg/datalv
$ resize2fs /dev/datavg/datalv

$ df -h /srv/data
/dev/mapper/datavg-datalv  613M  241M  343M  42% /srv/data
$ journalctl -u ingest -n 1 -o cat
# quiet — it is writing again
```

The writer never stopped. It spent the outage failing on every write and
recovered the moment there was space, without a restart and without losing its
place.

### Why this is a lesson at all

Two things, and the second is the one that matters at 3am.

1. **Capacity has layers, and each reports honestly about itself.** `vgs` saying
   "36M free" and `df` saying "0 available" are both true. The mistake is
   treating any one of them as "how much space do we have" — the only layer the
   application experiences is the filesystem, and it is the last one to hear
   about a change.

   This is the same shape as `inodes-not-bytes` in module 01: one accurate
   number, and a conclusion drawn from it that the number does not support.

2. **The dangerous moment is when the first two commands succeed.** `vgextend`
   and `lvextend` both report success and change nothing the application can
   see. Someone under pressure, watching `df` stay at 100%, concludes the
   extend did not work and starts trying other things — deleting the backlog is
   the obvious one, and the check refuses it for that reason.

   When a change reports success and the symptom does not move, the usual cause
   is that you changed a real thing at the wrong layer.

Worth knowing where the ceiling is: this all works because the volume manager
was there before the emergency. A filesystem on a raw partition cannot be grown
by adding a disk — you get to copy the data somewhere else with the service
down. The decision that made tonight easy was made when the box was built.

</details>
