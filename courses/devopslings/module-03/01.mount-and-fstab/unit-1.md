---
title: "the fstab line that stops the box half way through boot"
---

## The situation

Somebody added the archive volume to `/etc/fstab` yesterday, tested it, and went
home:

```
$ tail -1 /etc/fstab
/dev/loop0  /srv/archive  ext3  defaluts  0  1
```

They tested it like this:

```
$ mount /srv/archive
```

…which worked, because `mount` given a mount point looks up the entry, takes the
device, and figures out the filesystem type itself. It never had to agree with
the fields that are wrong.

The next thing to read that line will be `systemd` at boot, and it reads all six
fields.

## Your objective

Fix the entry so that:

- `findmnt --verify` reports no errors
- `mount -a` mounts the archive volume at `/srv/archive`
- **the entry does not stop the boot if the device is missing**

The volume contains `.volume-id`; the check reads it to confirm the right
filesystem is mounted, not just that something is.

## What you're being graded on

A clean `findmnt --verify`, `nofail` present, a `passno` that is not 1, and
`mount -a` actually bringing up the archive volume from a cold start.

<details>
<summary>Hint 1 — the six fields</summary>

```
<device>  <mount point>  <type>  <options>  <dump>  <pass>
```

| field | what it is | what goes wrong |
|---|---|---|
| device | what to mount | a name that moves (next lesson) |
| mount point | where | rarely wrong |
| type | `ext4`, `xfs`, `nfs` | wrong type, hidden by `mount` guessing |
| options | `defaults,nofail,noatime` | typos here are fatal at boot |
| dump | almost always `0` | harmless |
| pass | fsck order: `0` skip, `1` root, `2` everything else | `1` on a non-root filesystem |

Validate the file rather than reading it:

```
$ findmnt --verify
```

It parses every line the way the boot does and names each problem. Run it before
you reboot anything, always.

</details>

<details>
<summary>Hint 2 — why `mount /srv/archive` proved nothing</summary>

Three of the six fields are wrong and the manual test passed anyway:

- **`ext3`** — `mount` probes the superblock and uses the real type. At boot,
  systemd generates a `.mount` unit from this line and the type matters.
- **`defaluts`** — an unparsable option. This is the one that hurts: a bad
  options field makes the mount fail, and a mount that fails at boot without
  `nofail` drops the machine into emergency mode.
- **`1`** — reserved for the root filesystem. Two filesystems claiming pass 1 is
  a real fsck ordering bug.

The general shape: **testing a config by using it interactively exercises a
different code path from the one that will use it in anger.** Same as
`cron-and-path` in module 01, where the script worked by hand and not from cron.

</details>

<details>
<summary>Hint 3 — `nofail`, and what happens without it</summary>

Without `nofail`, a device that is absent at boot is a **fatal** error. systemd
waits for the device, times out, and drops to emergency mode — a root password
prompt on a console nobody is watching, on a machine that is otherwise perfectly
healthy.

For anything that is not the root filesystem, that is almost never the trade you
want: an unavailable archive volume should not stop a box from booting and
serving traffic.

```
defaults,nofail
```

Worth pairing with `x-systemd.device-timeout=10s`, so a slow or missing device
delays boot by ten seconds rather than the default ninety.

</details>

<details>
<summary>Solution</summary>

```
$ uuid=$(blkid -s UUID -o value /dev/loop0)
$ sed -i '\#/srv/archive#d' /etc/fstab
$ printf 'UUID=%s  /srv/archive  ext4  defaults,nofail  0  2\n' "$uuid" >> /etc/fstab

$ findmnt --verify
Success, no errors or warnings detected

$ umount /srv/archive; mount -a
$ cat /srv/archive/.volume-id
archive-volume-2026
```

`UUID=` rather than `/dev/loop0` is not required to pass this lesson, and it is
the right habit — the next exercise is what happens when that name moves.

### Why this is a lesson at all

`/etc/fstab` is one of a small number of files where a typo is not a runtime
error but a **failure to boot**, and where the feedback arrives at the worst
possible moment: during a reboot you are already doing for some other reason,
often remotely, on a machine you now cannot reach.

Three things worth keeping:

1. **Validate the file, do not test the operation.** `mount /srv/archive`
   exercises a forgiving path. `findmnt --verify` reads it the way the boot
   does. One command, and it is the difference between finding this now and
   finding it during a maintenance window.

2. **`nofail` on everything that is not root.** The default is "this filesystem
   is essential, stop the machine without it", which is correct for `/` and
   wrong for basically everything else.

3. **A successful manual test is weak evidence.** It shares almost nothing with
   the automated path — different code, different assumptions, a different set
   of fields consulted. This is the module-01 lesson about cron, restated one
   file over.

</details>
