---
title: "the service that is leaking 200 MB, except for the part that is not"
---

## The situation

catalog-api's memory has gone from 40M this morning to over 200M, and it never
comes down. The graph the team is watching reads `memory.current` for the unit's
cgroup.

```
$ cg=/sys/fs/cgroup$(systemctl show -p ControlGroup --value catalog-api)
$ cat $cg/memory.current
211812352
```

The proposed fix is a nightly restart. Before agreeing to that, look at what the
number is made of.

## Your objectives

| file | answer |
|---|---|
| `/root/answers/reclaimable` | one of `anon`, `file`, `slab`, `none` |

Then fix the actual leak. The check runs the service through two rounds of work
and requires the non-reclaimable part to stay flat between them.

catalog-api must keep re-reading `/srv/catalog/catalog.dat` every cycle — that
read is its job, not the bug.

## What you're being graded on

The named category, and `anon` growing by less than 4M across a second round of
identical work. The check reads the cgroup directly and fails if it cannot,
rather than treating an unreadable counter as "no growth".

<details>
<summary>Hint 1 — memory.current is a total, and totals hide things</summary>

```
$ cat $cg/memory.stat | head -6
anon 12582912
file 188743680
kernel 3close
slab 1638400
...
```

Two large numbers, and they are completely different kinds of memory:

- **`file`** — page cache. Copies of file contents the kernel is keeping because
  the RAM is not needed for anything else. Every byte has a home on disk.
- **`anon`** — anonymous memory. The heap. There is no file behind it, so it
  cannot simply be dropped.

180M of the 200M is `file`, and it is there because the service reads a 180M
catalogue on every cycle. That is not the application holding memory; it is the
kernel doing its job.

</details>

<details>
<summary>Hint 2 — what "reclaimable" actually means</summary>

Page cache is **free memory that is being useful in the meantime.** When
anything needs RAM, the kernel drops clean page cache immediately — no
notification, no involvement from the process, no swapping.

That is why a Linux box showing "almost no free memory" is normal and healthy.
Memory not being used for anything is memory being wasted.

Prove it to yourself:

```
$ free -m                  # note buff/cache
$ cat $cg/memory.stat | grep -E '^(anon|file) '
```

The consequences for this incident:

- The nightly restart would "work" — memory drops. It drops because the page
  cache is discarded, and it refills within minutes of the service running
  again. Nothing was fixed.
- Alerting on total memory produces exactly this page, on a healthy service,
  forever.

`anon` is the number that matters. Watch that instead:

```
$ while :; do awk '/^anon /{print $2/1048576 "M"}' $cg/memory.stat; sleep 5; done
```

</details>

<details>
<summary>Hint 3 — the small number that is the real problem</summary>

`anon` is 12M and climbing steadily — about 256 KiB per cycle. Small, boring, and
it never comes back.

```python
leaked = []
...
    leaked.append(bytearray(256 * 1024))
```

A buffer appended to a list that nothing ever reads or empties. The list keeps a
reference, so the allocator can never reuse the memory.

The test for a leak is not the absolute number — it is whether the number is
**proportional to work done**. Page cache plateaus at the size of the data
being read. A leak keeps climbing as long as the service keeps working, which
is why the check measures growth across two identical rounds rather than a
value at one moment.

</details>

<details>
<summary>Solution</summary>

```
$ echo file > /root/answers/reclaimable
```

```python
    # Nothing retains this now, so the allocator reuses the same memory each
    # cycle.
    scratch = bytearray(256 * 1024)
    del scratch
```

```
$ systemctl restart catalog-api
$ # anon holds flat across rounds; file climbs back to ~180M and stops
```

### Why this is a lesson at all

The monitoring was accurate. `memory.current` really did go from 40M to 200M.
Every step of the reasoning that followed was wrong, and the proposed fix — a
nightly restart — would have appeared to work indefinitely while the actual leak
carried on underneath.

Three things worth keeping:

1. **On Linux, "memory used" is not one number.** Page cache is counted in
   totals and is not the application's in any meaningful sense. Any alert on
   total memory for a service that reads files will fire, be acknowledged, and
   train people to ignore it. Alert on `anon`, on working set, or on pressure
   (`memory.pressure`) — not on a total that includes cache.

2. **A leak is a slope, not a value.** 12M of `anon` means nothing on its own.
   12M growing to 24M over the same amount of work again is the whole
   diagnosis. This is the fourth time this module and the last have used the
   same technique — descriptors in `too-many-open-files`, inodes in
   `inodes-not-bytes`, journal bytes in `journal-eats-the-disk`, anon here.
   Measure across two identical rounds and compare.

3. **A restart that "fixes" it is evidence about the restart, not the bug.**
   Dropping page cache makes the graph fall, so the ritual appears to work, and
   the real leak keeps going. Whenever a restart resolves a resource problem,
   the question to ask is *which* resource it actually released.

</details>
