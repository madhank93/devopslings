---
title: "writes that took a millisecond stop for seconds at a time"
---

## The situation

The ingest service writes 1.2 million records into an LSM store — a real
RocksDB, driven by `db_bench`, which is the client and the store at once.

```
cat /work/app/ingest.sh
/work/app/ingest.sh
```

The median write takes about three microseconds. Several times during the run
everything stops for a second or more, and the periodic lines in
`/work/ingest.log` show the rate collapsing and recovering.

The filesystem is 30% full. `iostat` during a pause shows the device idle.

The ticket says the storage is slow and asks for the volume to be moved to
faster disk.

## Your objectives

- The same job — 1.2 million records of 800 bytes under random keys — with the
  slowest 0.1% of writes inside 500 microseconds and under 10% of the run spent
  stalled
- Level 0 drained by the end, not merely allowed to grow
- No shortcuts on the data: the store has to still hold all of it

## What you're being graded on

The check runs your `/work/app/ingest.sh`, then reads the store's own numbers
out of `/work/ingest.log` and `/work/store/LOG`: `1200000 operations`, at least
600 MB on disk, `rocksdb.stall.micros` under 10% of the elapsed time, `P99.9`
under 500 microseconds, and no more than 24 files left at level 0 — the pile has
to have drained, not just stopped being refused. Leave `--statistics` and
`--histogram` on: those numbers are the evidence. You also fill in
`/work/answers/stall.md`.

<details>
<summary>Hint 1 — the store says why it stopped</summary>

An LSM store that pauses writes writes down the reason:

```
grep -E '(Stalling|Stopping) writes' /work/store/LOG | sort | uniq -c | sort -rn | head -5
```

```
     61 Stopping writes because we have 4 level-0 files
      9 Stalling writes because we have 3 level-0 files rate 8388608
```

And the total, in the statistics block at the end of the run:

```
grep -E 'rocksdb.stall.micros|rocksdb.db.write.stall' /work/ingest.log
```

Compare that total against the `seconds` in the `fillrandom` line. If most of
the run is in there, the store was not slow — it was stopped, on purpose, for
most of the run.

Nothing was waiting on the disk. The store refused the write itself.

</details>

<details>
<summary>Hint 2 — why level-0 is different from the other levels</summary>

A write lands in a memtable. A full memtable is *flushed* to a file at level 0.
Level-0 files are the only ones that may overlap each other in key range, so a
read has to look in all of them, and merging them into level 1 — *compaction* —
is the work that stops that from growing.

Two counts and three thresholds:

| option | what it does at that many level-0 files |
|---|---|
| `level0_file_num_compaction_trigger` | start compacting |
| `level0_slowdown_writes_trigger` | begin delaying writes |
| `level0_stop_writes_trigger` | stop writes entirely until it drains |

The last two are back-pressure: the store's way of refusing to let an unbounded
read amplification build up behind an ingest it cannot keep up with. They are a
symptom of the arithmetic, not a cause.

So there are exactly two ways to be under those thresholds: produce level-0
files more slowly, or merge them away faster.

```
grep -E 'write_buffer_size|level0|background_jobs' /work/app/ingest.sh
```

A 4 MB memtable turns 1 GB of ingest into 250 flushes. One background job has
to compact all of them, one at a time, and it cannot.

</details>

<details>
<summary>Hint 3 — three knobs, in order of how much they move</summary>

**Flush less often.** `--write_buffer_size=33554432` — a 32 MB memtable is an
eighth of the level-0 files for the same data. This is the biggest single win,
and it costs memory: 32 MB per memtable held in RAM, and a longer replay if the
process dies.

**Give compaction enough threads.** `--max_background_jobs=4`, and
`--subcompactions=2` to split one level-0-to-1 compaction across cores. Costs
CPU, which the write path also wants.

**Stop triggering on two files.** `--level0_file_num_compaction_trigger=4`,
`--level0_slowdown_writes_trigger=20`, `--level0_stop_writes_trigger=36` — the
RocksDB defaults. Three files is a threshold a healthy store crosses all day.
Raising them costs read amplification, and raising them *alone* would leave the
backlog growing with nothing to stop it.

That last point is the trap: raising the triggers makes the stall counter go
quiet without making compaction keep up. It is the one fix that looks like it
worked.

</details>

<details>
<summary>Solution</summary>

```bash
db_bench --db=/work/store \
  --benchmarks=fillrandom --num=1200000 --value_size=800 \
  --compression_type=none --statistics --histogram=1 \
  --stats_interval_seconds=5 \
  \
  --write_buffer_size=33554432 \
  --max_write_buffer_number=8 \
  --level0_file_num_compaction_trigger=4 \
  --level0_slowdown_writes_trigger=20 \
  --level0_stop_writes_trigger=36 \
  --max_background_jobs=4 \
  --subcompactions=2 \
  > /work/ingest.log 2>&1
```

Measured in the sandbox, two cores:

| | before | after |
|---|---|---|
| elapsed | 39 s | 6 s |
| throughput | 31,000 ops/sec | 189,000 ops/sec |
| time stalled | 33 s (86%) | 0 |
| P99.9 write | 4,074 µs | 29 µs |
| level-0 stalls in LOG | 160 | 0 |

Same data, same disk.

### The part worth remembering

**A write stall is the store protecting the read path, not the disk
complaining.** Level-0 files overlap, so every one of them is a file every read
has to check. When compaction falls behind, the store's choice is unbounded
read latency or paused writes, and it picks paused writes. Understanding it as
back-pressure rather than as slowness is what stops you from buying hardware.

**The median was never the problem.** Three and a half microseconds at P50
and nearly 4 ms at P99.9: a median cannot see a pause that hits one write in a
thousand, and the pause is what the service felt. Any latency SLO on an LSM store belongs on a
tail percentile — and on a store whose failure mode is a multi-second stop, P99
is not far enough out.

**Flush rate and compaction rate are one arithmetic problem.** Level-0 file
count is the integral of the difference between them. Every knob here is one
side of that subtraction: memtable size and flush concurrency on one side,
background jobs, subcompactions and any rate limiter on the other. Tune them
together or you have only moved which one is binding.

**Raising the threshold is the fix that looks like it worked.** The stall
counter goes quiet, throughput goes up, and level-0 keeps growing with nothing
left to stop it — until reads slow down instead, somewhere else, later, for
reasons that no longer point at this change. Any time a fix consists of raising
the number in the error message, check what the number was protecting.

**Every knob spends something.** Bigger memtables spend RAM and crash-recovery
time. More background threads spend CPU the write path wanted. Higher triggers
spend read amplification. There is no setting that makes an LSM store cheap on
all three — pick which one the workload can afford, and know which you paid.

</details>
