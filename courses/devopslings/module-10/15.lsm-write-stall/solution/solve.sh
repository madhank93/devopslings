#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The pauses are the store's own back-pressure: level-0 files arrive from
# flushes faster than one compaction thread can merge them into level 1, the
# count crosses the slowdown and then the stop trigger, and the write path is
# held until it comes down.
#
# Three knobs, in the order they matter: flush less often (a 32 MB memtable
# instead of 4 MB produces an eighth of the level-0 files), give compaction
# enough threads to keep up, and stop triggering on two files — two is a
# threshold a healthy store crosses all day.
set -euo pipefail

sed -i \
  -e 's/--write_buffer_size=4194304/--write_buffer_size=33554432/' \
  -e 's/--level0_file_num_compaction_trigger=2/--level0_file_num_compaction_trigger=4/' \
  -e 's/--level0_slowdown_writes_trigger=3/--level0_slowdown_writes_trigger=20/' \
  -e 's/--level0_stop_writes_trigger=4/--level0_stop_writes_trigger=36/' \
  -e 's/--max_background_jobs=1/--max_background_jobs=4 \\\n  --subcompactions=2/' \
  /work/app/ingest.sh

grep -E 'write_buffer_size|level0|background_jobs|subcompactions' /work/app/ingest.sh

install -d /work/answers
cat > /work/answers/stall.md <<'MD'
# The ingest pauses

# One line: what was the write path waiting on while it was stopped?
what-the-write-waited-on: compaction falling behind — level-0 files were arriving from flushes faster than one background thread could merge them into level 1, and the write path was held until the count came back under the trigger

# The counter that proves it, by the name the store gives it — from the
# statistics block, or from the reason the store's LOG records for each
# pause.
the-counter: rocksdb.stall.micros in the statistics block, and the LOG records each pause as "Stopping writes because we have N level-0 files" (or "Stalling" for a slowdown)

# The device is idle between the pauses and the filesystem is 30% full.
# One line: why does moving this to a faster disk not fix it?
why-not-a-faster-disk: nothing is waiting on the device — the store is refusing the writes itself, because the level-0 file count crossed a threshold it was configured with, and a faster disk only helps to the extent compaction was disk-bound rather than limited to one thread

# One line: your fix spends a resource to buy the write latency back.
# Which one?
what-the-fix-cost: memory and CPU — a 32 MB memtable holds eight times as much unflushed data in RAM and lengthens recovery after a crash, and three more background threads compete with the write path for the two cores this container has
MD

echo "ingest options rewritten: 32MB memtable, 4/20/36 triggers, 4 background jobs"
