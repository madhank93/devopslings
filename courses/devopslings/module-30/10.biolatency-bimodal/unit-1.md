---
title: "average await is 3 ms, and 1% of writes take 200 ms"
---

## The situation

`ledger-writer.service` appends a 4 KiB record to `/srv/ledger` every 20 ms,
each one durable (`O_DSYNC`) before it returns. Its log every 30 seconds:

```
$ journalctl -u ledger-writer -n 2 -o cat
writes=1402 mean=0.81ms p50=0.55ms max=104.0ms
```

A mean under a millisecond, and a max a hundred times that. `iostat -x` on the
volume agrees with the mean: an average await of a few milliseconds, nothing a
storage team would look at twice. Module 03's `iostat-await-versus-util` read
averages, and here the average is the thing hiding the problem.

The first guess is "the average is fine, so the disk is fine". An average of a
distribution with two humps describes neither of them.

## What biolatency shows

`biolatency` (libbpf-tools) times every block I/O from issue to completion in
the kernel and prints a power-of-two histogram:

```
$ findmnt -no SOURCE /srv/ledger
/dev/loop13
$ biolatency -d loop13 30 1
     usecs               : count    distribution
        64 -> 127        : 1238     |****************************************|
       ...
```

Run it for at least 30 seconds — the slow writes do not arrive evenly — and read
the whole shape, not the top bucket. Then find whose I/O is in the slow part:
`biosnoop -d loop13` prints each I/O with its process, size and latency.

## Your objectives

1. Name the slow mode's range, and the process and behaviour that cause it, in
   `/root/answers/biolatency.md`:

   ```
   second-mode: <lo>-<hi> <us or ms>
   cause: <which process, doing what>
   ```

2. Make the second mode go away. `metrics-compactor` must keep writing the same
   128 MB snapshot, every 15 seconds, durably.

## What you're being graded on

- `second-mode` is the slow hump's range in the histogram init recorded, give or
  take a bucket — not the main hump, not the average
- `cause` names the process and what it does that builds the slow mode
- in a fresh 33-second histogram of the volume, under half a percent of I/Os
  land in the slow range, while the compactor completes its snapshots on time
- the compactor's snapshot size and interval are unchanged, neither program is
  edited, and the host-wide `vm.dirty_*` sysctls are untouched
- the snapshot still lands on the ledger volume, and the volume is still the
  same direct-I/O loop device — moving the burst somewhere the histogram cannot
  see it is not a fix

<details>
<summary>Hint 1 — reading a bimodal histogram</summary>

Find the tallest bucket; that is where most I/Os land. Then read upwards: the
counts fall away to almost nothing, and then rise again. The second rise,
between the near-empty buckets and the top of the histogram, is the second
mode. Its range is the buckets it spans, in the histogram's unit.

</details>

<details>
<summary>Hint 2 — who is in the slow mode</summary>

```
$ biosnoop -d loop13 | awk '$NF > 10'
```

prints only I/Os that took over 10 ms. Look at the process, the size of each
I/O, and when they arrive. Then look at `/etc/metrics-compactor.conf` and
`/var/log/metrics-compactor.log`.

</details>

<details>
<summary>Hint 3 — same bytes, different queue</summary>

The compactor writes 128 MB into the page cache, which costs the disk nothing,
and then calls `fsync` once. At that moment the whole snapshot is sent to the
device together, and every ledger write issued during the next hundred
milliseconds queues behind it. The total bytes are not the problem. The amount
outstanding at once is.

</details>

<details>
<summary>Solution</summary>

```
$ cat > /root/answers/biolatency.md <<'TXT'
second-mode: 16384-131071 us
cause: metrics-compactor writes a 128 MB snapshot and fsyncs it in one burst every 15 s
TXT
$ sed -i 's/^flush_every_mb = .*/flush_every_mb = 1/' /etc/metrics-compactor.conf
$ systemctl restart metrics-compactor
$ biolatency -d loop13 30 1
```

(Your range is whatever your histogram shows.) With an fsync every megabyte,
at most a megabyte of the compactor's data is queued at the device at a time,
and a ledger write waits behind that instead of behind the whole snapshot. The
compactor writes the same 128 MB, every 15 s, and every byte is on disk before
it renames the snapshot into place.

### The ways this goes wrong

- **Reading the average.** It is dominated by the thousands of fast writes, and
  the hundred slow ones move it by a millisecond.
- **Naming the tallest bucket.** That is how long most writes take. The problem
  is the hump that only a few writes are in.
- **Blaming `jbd2` or `kworker`.** They issue the I/O; the data is the
  compactor's.
- **A smaller or rarer snapshot.** Fewer bursts, or smaller ones, and less of the
  data the compactor exists to keep.
- **Tuning `vm.dirty_background_bytes`.** It would start writeback earlier, and
  it is not namespaced: from this box it changes the Docker host's kernel.

</details>

## Why the average lies

A latency distribution from a storage device is rarely one hump. Cache hits and
misses, reads and writes, and here, writes queued behind a burst and writes that
were not, each form their own. An average sums them into a number none of the
writes actually took. `biolatency` exists because the shape is the diagnosis:
two humps means two populations, and the work is finding what puts an I/O in
the slow one.
