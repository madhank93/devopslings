---
title: "the busy disk is fine and the quiet one is the outage"
---

## The situation

Two volumes. `catalog` serves index lookups for catalog-api; `audit` takes the
audit log's durable writes. The audit writes have been slow for a week.

The storage vendor has quoted for replacing the volume showing the higher
utilisation. Finance wants a second opinion before signing.

```
$ cat /srv/reports/iostat.txt
Device       r/s      rkB/s   r_await   w/s    wkB/s   w_await   aqu-sz  %util
catalog  51374.67 6575957.33    0.04    0.00     0.00     0.00     1.93  83.12
audit        0.00       0.00    0.00 1125.17 36010.67     1.32     1.49  41.55
```

`storage-probe` re-runs the measurement whenever you want it.

## Your objectives

| file | answer |
|---|---|
| `/root/answers/saturated` | `catalog` or `audit` |
| `/root/answers/metric` | one of `util`, `await`, `iops`, `queue-depth` |
| `/root/answers/util-means` | one of `capacity`, `residency`, `throughput`, `latency` |

## What you're being graded on

Naming the bottleneck, the column that identifies it, and what `%util` actually
measures. The third one is the reason the first two are hard.

<details>
<summary>Hint 1 — read the table by column and see which columns disagree</summary>

Line them up:

| | catalog | audit |
|---|---|---|
| %util | 83% | 42% |
| iops | 51,000/s | 1,125/s |
| aqu-sz | 1.93 | 1.49 |
| await | 0.04 ms | 1.32 ms |

Three of those columns say `catalog` is working much harder. One says something
different, and it is the only one measuring what a request *costs* rather than
how many there were or how often the device was occupied.

`catalog` is doing forty-five times the requests at one thirty-third the cost
each. `audit` is doing almost nothing, slowly.

Note especially that the queue depths are nearly the same. A queue tells you
requests are waiting; it does not tell you whether waiting is unusual for that
device.

</details>

<details>
<summary>Hint 2 — what %util is actually counting</summary>

`%util` is the fraction of the sample interval during which the device had **at
least one request in flight**. That is all. It is a measure of *time occupied*,
not of *capacity consumed*.

Two consequences, and both are in this table:

- A device handed a constant stream of instant requests reads ~100%. It is
  always occupied and never struggling. That is `catalog`.
- A device handed one slow request at a time can also read ~100% while moving
  almost no data.

So `%util` cannot distinguish "busy" from "saturated", and it never could. It
was a decent proxy on a single mechanical spindle that served exactly one
request at a time — one request in flight really did mean the device was fully
committed. Every device since, from a RAID set to an SSD to anything with a
queue, serves many at once, and the proxy broke without the metric changing its
name.

</details>

<details>
<summary>Hint 3 — why the audit volume is slow, and why that is not a disk problem</summary>

The audit writes are `O_DIRECT | O_SYNC`. Every one of them has to reach the
device before it is acknowledged, so each write pays a full round trip, and no
amount of queueing hides it. The service measures roughly 3 ms per write against
`catalog`'s 0.07 ms per read.

That is the cost of durability, which is a design decision an audit log is
entitled to make. Whether the answer is a faster device, batching writes and
fsyncing per batch, or accepting the latency, all depends on knowing where the
time goes — and the utilisation graph would have sent someone to buy the wrong
disk for the volume that had nothing wrong with it.

</details>

<details>
<summary>Solution</summary>

```
saturated:   audit
metric:      await
util-means:  residency
```

The USE method — utilisation, saturation, errors — is worth carrying out of
this, along with the observation that Linux's `%util` is not the U in it.
Saturation is about work that is *waiting*, and for a disk the honest signals
are service time per request and how deep the queue is relative to what the
device can serve concurrently.

The general shape, and it recurs well beyond disks: a metric that was a valid
proxy under an assumption keeps reporting confidently after the assumption stops
being true. Nothing errors. The number is correct — it is the inference that is
stale. It is the same failure as reading CPU utilisation on a throttled cgroup,
which is the lesson two doors down.

</details>
