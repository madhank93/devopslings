---
title: "ingest is slow, some writes fail, and every graph has an excuse"
---

## The situation

```
$ ingest-stats
last 30s: 212 records, 61 failed   p50 14.2ms   p99 391.0ms   max 402.7ms
     61  deadline exceeded (100ms)
```

The ingest service's p99 has degraded and some of its writes fail. That is the
entire ticket, and it will be the entire ticket every time you run this lesson.
The fault is drawn at random from five, and each one sits in a different layer
under the same service. The output above is one of them, and the next run may
look nothing like it.

`ingest.service` runs `/opt/ingest/ingest.py` as the user `ingest`. For every
record it:

1. probes a 192 MB in-memory dedup index,
2. appends the record to `/srv/ingest/records`, an ext4 filesystem on the LVM
   volume `ingestvg/ingestlv`,
3. logs it to a WAL on `/srv/ingest-wal`, a volume of its own, and
4. forwards it over a fresh TCP connection to the replica at `10.203.0.10:9100`.

A record that takes more than 100 ms has failed. `/var/lib/ingest/records.log`
has one line per record (time, `ok` or `fail`, milliseconds, reason), and
`ingest-stats` summarises it.

You cannot memorise the answer, but you can memorise the order of the questions.

## Your objectives

- Make ingest meet its deadline again by repairing what broke, where it broke
- Write `/root/answers/triage.md`, three lines:

  ```
  cause:     <what was wrong, in a few words>
  evidence:  <the command or counter that proved it>
  detection: <a signal and a threshold that would have paged first>
  ```

## What you're being graded on

The grader restarts ingest and re-applies the sysctl configuration first, so
anything you did only to the live process or the running kernel is undone.
Then it watches 12 seconds of records. At least 60 must be logged, and no more
than 1% may fail. It also checks that:

- **the program and its config are unchanged.** That includes the 100 ms
  deadline, because a longer deadline only hides the failures from the report.
- **ingest still runs as `ingest` and keeps a CPU limit and a memory limit.**
  If a limit is wrong, give it a better number. Don't delete it, and don't set
  it with `--runtime`, because the next boot forgets that.
- **everything in `/srv/ingest/backlog` is intact.** It is data waiting to be
  processed, not the thing filling the disk.
- **each of `/srv/ingest-wal` and `/srv/scratch` holds its own volume.**
- **the seeded cause is fixed where it lives.** That means the filesystem the
  size of its volume, `fstab` naming filesystems rather than devices, or the
  ephemeral port range wide again after the configuration is re-applied.
- **`catalog-warm.service` is still running, unchanged.** Its volume shows the
  highest `%util` on the box, and it has nothing to do with ingest.

For `triage.md`, `cause` must describe the fault that was seeded. `evidence`
must be the command or counter that proves that fault. `detection` must name a
signal that fits the fault *and* give a number.

<details>
<summary>Hint 1 — the questions, in order</summary>

Start with the reason ingest gives, then ask the kernel the question that
reason points at:

```
$ ingest-stats                          # what fails, and how
$ journalctl -u ingest -n 20            # the first failure, in its own words

$ findmnt /srv/ingest-wal; losetup -l   # is each mount the volume it is named for?
$ cat /srv/ingest-wal/.volume-id
$ df -h /srv/ingest; lvs                # is the filesystem the size of its volume?
$ ss -s; sysctl net.ipv4.ip_local_port_range

$ cg=/sys/fs/cgroup$(systemctl show -p ControlGroup --value ingest)
$ cat $cg/cpu.stat                      # nr_throttled: suspended with cores idle?
$ grep -E '^(anon|pswpin) ' $cg/memory.stat   # paging against its own limit?
```

Read each counter twice, a few seconds apart. A counter going up is evidence,
and a counter that is merely large is not.

</details>

<details>
<summary>Hint 2 — two of the five say only "deadline exceeded"</summary>

When the reason is a deadline, the record was not refused. It was slow. Either
the process was waiting for CPU it was not allowed to have, or it was waiting
for memory it had to fetch back. `top` says neither: the box has idle cores
and gigabytes free. The unit's cgroup knows which: `nr_throttled` in
`cpu.stat` counts periods in which it was suspended, and `pswpin` in
`memory.stat` counts pages it had to read back from swap.

`systemctl cat ingest` shows every file that sets its limits.

</details>

<details>
<summary>Hint 3 — the busiest disk on the box</summary>

```
$ iostat -x -N 2
```

One loop device sits far above the rest, at 60–80% `%util`. Look at its
`r_await` before you decide it is a problem, and at `losetup -l` to see what it
is. `%util` is the share of time the device had at least one request in
flight. A reader that keeps issuing fast requests scores high while each
request finishes in a fraction of a millisecond. That device is busy, not
saturated, and ingest never touches it.

</details>

## What actually happened

| Fault | What was done | What ingest says | The tell |
|---|---|---|---|
| cpu | the platform-limits drop-in set `CPUQuota=2%` | `deadline exceeded` | `nr_throttled` climbing in `cpu.stat`, with cores idle |
| memory | the same drop-in set `MemoryMax=96M`, under a 192 MB index | `deadline exceeded` | `pswpin` climbing in `memory.stat`, with gigabytes free |
| resize | `lvextend` grew `ingestlv` to 320M; the filesystem stayed 192M and the import filled it | `No space left on device` | `lvs` says 320M, `df` says 192M |
| fstab | `fstab` rewritten to `/dev/loopN`, then the volumes reattached the other way round | `No such file or directory` on the WAL | `/srv/ingest-wal/.volume-id` says `scratch` |
| ports | a `sysctl.d` baseline set `ip_local_port_range` to ten ports | `Cannot assign requested address` | `ss` shows every port in the range in `TIME_WAIT` |

The red herring is the same on every run. `catalog-warm.service` re-reads the
catalog volume with back-to-back 1 MB direct reads. `iostat` puts that device
at 60–80% `%util` with an `r_await` under 0.1 ms. Stopping
it changes nothing for ingest, because ingest never reads that volume.

<details>
<summary>Solution</summary>

Ask in order, and repair at the first question that answers.

```bash
cg=/sys/fs/cgroup$(systemctl show -p ControlGroup --value ingest)
LIM=/etc/systemd/system/ingest.service.d/50-platform-limits.conf

# fstab: the WAL mount holds the wrong volume
findmnt /srv/ingest-wal; losetup -l; cat /srv/ingest-wal/.volume-id
blkid -s UUID -o value "$(blkid -L ingest-wal)"   # put UUID=… in fstab, then
blkid -s UUID -o value "$(blkid -L scratch)"      # the same for scratch
systemctl stop ingest
umount /srv/ingest-wal /srv/scratch && mount /srv/ingest-wal && mount /srv/scratch
systemctl start ingest

# resize: the volume grew, the filesystem did not
lvs ingestvg; df -h /srv/ingest
resize2fs /dev/ingestvg/ingestlv           # online, no unmount

# ports: ten ephemeral ports for one connection per record
ss -Htan state time-wait | wc -l; sysctl net.ipv4.ip_local_port_range
grep -r ip_local_port_range /etc/sysctl.d  # remove it from that file, then
sysctl -w net.ipv4.ip_local_port_range="32768 60999"

# cpu: suspended with idle cores
cat $cg/cpu.stat; sleep 3; cat $cg/cpu.stat
sed -i 's/^CPUQuota=.*/CPUQuota=100%/' $LIM
systemctl daemon-reload && systemctl restart ingest

# memory: paging against its own limit
grep pswpin $cg/memory.stat; sleep 3; grep pswpin $cg/memory.stat
sed -i 's/^MemoryMax=.*/MemoryMax=512M/' $LIM
systemctl daemon-reload && systemctl restart ingest
```

Then, for example:

```
cause: CPUQuota=2% in the platform-limits drop-in, so ingest was throttled with idle cores
evidence: nr_throttled climbing in the unit's cpu.stat
detection: nr_throttled / nr_periods > 10% over 5 minutes
```

</details>

## Carrying this forward

- **The reason a write fails narrows the layer, and only that.** `ENOSPC`
  sends you to the filesystem, but the question is whether the filesystem is
  the size of its volume. `ENOENT` on a path that existed yesterday is a
  question about what is mounted there.
- **"Slow" is CPU or memory you were not allowed to have.** Machine-wide
  graphs cannot show either. The unit's `cpu.stat` and `memory.stat` can.
- **Configuration is what survives.** `sysctl -w`, a hand `mount`, and a value
  written straight into a cgroup file all last until the next boot or restart.
  The fix belongs in the file that would have put the fault back.
- **Leave the busiest thing alone until it is proven guilty.** `%util`
  measures how often a device is busy, not how close it is to its limit.

Run the lesson again. The fault moves, and the questions do not.
