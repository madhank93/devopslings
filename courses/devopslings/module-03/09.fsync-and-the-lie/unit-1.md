---
title: "the write returned committed and the record is not there"
---

## The situation

The vault ledger acknowledged eleven payments last night. After the power event,
ten are in the file.

```
$ ledger-append "txn-9912 settled 100.00"
committed
$ echo $?
0
```

The service is not silently failing. It writes the record, pushes it out of its
own buffer, prints `committed`, and exits 0. Every one of those eleven calls did
exactly that, and one payment is gone.

## Your objectives

| file | answer |
|---|---|
| `/root/answers/layer` | one of `application-buffer`, `page-cache`, `device-cache` |

Then make `ledger-append` durable. The check appends its own records through
your `ledger-append`, cuts the power to the volume underneath it, brings it
back, and requires every acknowledged record to still be there.

It must keep appending to `/srv/vault/ledger.log` and keep exiting 0 with the
record acknowledged.

## What you're being graded on

Six records appended through your tool, then a real power cut: the device-mapper
table under `/srv/vault` is suspended without flushing and swapped for an `error`
target, so everything in flight and everything still in memory is lost and the
disk keeps only what was persisted. All six have to be on the other side. The
check also confirms the durably-written opening balance came back, so a wiped
volume cannot be mistaken for a survived one.

<details>
<summary>Hint 1 — three layers, and two of them can be ruled out without an experiment</summary>

A record on its way to a disk passes through:

1. **the application's own buffer** — the `bytearray` behind a Python file
   object. Nothing outside the process knows about it.
2. **the page cache** — the kernel's copy. `write(2)` returns as soon as the
   data is here. This is not a bug, it is the whole reason writes are fast.
3. **the device write cache** — RAM on the drive, which may acknowledge a write
   before the platter or flash has it.

Now read the tool:

```python
with open("/srv/vault/ledger.log", "a") as f:
    f.write(record + "\n")
    f.flush()
```

`flush()` is precisely the call that empties layer 1 into layer 2. So layer 1
did what it claimed. And layer 3 is not in this story either — look at what the
volume actually is:

```
$ findmnt -no SOURCE /srv/vault
/dev/mapper/vault
$ dmsetup table vault
0 524288 linear 7:5 0
```

A device-mapper target over a loop file. There is no drive here, and nothing
with a volatile cache acknowledged anything. That leaves one layer, and it is
the one that is doing its job correctly.

</details>

<details>
<summary>Hint 2 — flush() and fsync() read like a pair and are not one</summary>

The confusion this lesson exists for:

| call | moves the data | waits for the disk |
|---|---|---|
| `f.flush()` | out of the process, into the kernel | no |
| `os.fsync(fd)` | out of the kernel, onto the device | yes |

`flush()` is about *your program*. `fsync()` is about *the machine*. A record
that has been flushed but not fsynced is entirely in RAM, owned by the kernel,
scheduled to be written out in the next thirty seconds or so — and until that
happens it is exactly as durable as a variable.

Every read confirms it is there, which is what makes this so convincing. `cat`
returns the record. `wc -l` counts it. The page cache serves reads from the same
copy that has not been written down.

</details>

<details>
<summary>Hint 3 — where the fsync goes</summary>

Inside the with-block, and before the acknowledgement:

```python
with open("/srv/vault/ledger.log", "a") as f:
    f.write(record + "\n")
    f.flush()
    os.fsync(f.fileno())

print("committed")
```

Ordering is the point. Acknowledging first and persisting afterwards is the same
bug with a smaller window, and a smaller window is the kind of bug that survives
years of testing and then costs one payment.

</details>

<details>
<summary>Solution</summary>

```
page-cache
```

plus `os.fsync(f.fileno())` after the flush and before the acknowledgement.

The general shape: **an acknowledgement is a promise about the worst case, and
every layer will happily make that promise on behalf of the layer below it.**
Each of the three layers here returns success the moment the data is *its*
problem rather than the caller's. None of them is broken. The bug is that the
service treated "the kernel has it" as "the disk has it", and nothing in the
success path distinguishes those two until the machine loses power.

Two things worth carrying:

- Durability costs a round trip to the device, every time, and that is why it is
  not the default. Batching records and fsyncing once per batch is a legitimate
  design — acknowledging each record individually before that fsync is not.
- For a newly *created* file, `fsync` on the file is not sufficient on its own:
  the directory entry needs its own fsync, or the file can come back missing
  even though its data was persisted. This lesson appends to a file that already
  exists, which is why one fsync is enough here.

</details>
