---
kind: lesson
title: "writes that took a millisecond stop for seconds at a time"
description: |
  The ingest service writes 1.2 million records into an LSM store and the
  average write is three microseconds. Then, several times a minute,
  everything stops for a second or more. The disk is 30% full and idle between
  the pauses. Nothing is broken — the store is doing this on purpose, and it
  will tell you why.
name: lsm-write-stall
slug: lsm-write-stall
createdAt: "2026-09-24"
timingSensitive: true

sandbox:
  stack: db-stack
  service: lsm

tasks:
  init_scenario:
    init: true
    timeout_seconds: 900
    run: |
      install -d /work/app /work/answers
      rm -f /work/answers/stall.md

      cat > /work/app/ingest.sh <<'SH'
      #!/usr/bin/env bash
      # The ingest path. db_bench is both the client and the store: it opens a
      # real RocksDB with these options and writes 1.2 million records of 800
      # bytes under random keys, as fast as the store will take them.
      #
      # The record count, the value size and the workload are the job. The
      # options below the blank line are ours to set.
      #
      # Leave --statistics and --histogram on: the numbers the store reports
      # about itself are what the check reads.
      set -euo pipefail
      DB=/work/store
      rm -rf "$DB"

      db_bench --db="$DB" \
        --benchmarks=fillrandom --num=1200000 --value_size=800 \
        --compression_type=none --statistics --histogram=1 \
        --stats_interval_seconds=5 \
        \
        --write_buffer_size=4194304 \
        --max_write_buffer_number=8 \
        --level0_file_num_compaction_trigger=2 \
        --level0_slowdown_writes_trigger=3 \
        --level0_stop_writes_trigger=4 \
        --max_background_jobs=1 \
        > /work/ingest.log 2>&1

      grep -E '^fillrandom' /work/ingest.log
      SH
      chmod +x /work/app/ingest.sh

      cat > /work/answers/stall.md <<'MD'
      # The ingest pauses

      # One line: what was the write path waiting on while it was stopped?
      what-the-write-waited-on: ?

      # The counter that proves it, by the name the store gives it — from the
      # statistics block, or from the reason the store's LOG records for each
      # pause.
      the-counter: ?

      # The device is idle between the pauses and the filesystem is 30% full.
      # One line: why does moving this to a faster disk not fix it?
      why-not-a-faster-disk: ?

      # One line: your fix spends a resource to buy the write latency back.
      # Which one?
      what-the-fix-cost: ?
      MD

      echo "running the ingest once, so there is something to look at…"
      /work/app/ingest.sh || true
      echo
      echo "scenario ready"
      echo
      echo "  the ingest:   /work/app/ingest.sh"
      echo "  its output:   /work/ingest.log"
      echo "  the store:    /work/store  (its own log is /work/store/LOG)"
      echo "  your answer:  /work/answers/stall.md"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 1800
    run: |
      ingest=/work/app/ingest.sh
      ans=/work/answers/stall.md
      log=/work/ingest.log
      db=/work/store

      if [ ! -s "$ans" ]; then
        echo "not yet: $ans is missing or empty"
        exit 1
      fi
      if grep -q ': *?$' "$ans" 2>/dev/null; then
        echo "not yet: $ans still has unanswered '?' fields"
        exit 1
      fi
      if [ ! -s "$ingest" ]; then
        echo "not yet: $ingest is missing or empty. The ingest is what has to get faster."
        echo "Run 'devopslings reset lsm-write-stall' to put the scenario back."
        exit 1
      fi

      field() {
        grep -E "^$1:" "$ans" 2>/dev/null | head -1 | sed "s/^$1: *//" | tr -d '\r' || true
      }

      rm -f "$log"
      rc=0
      timeout 1500 bash "$ingest" >/dev/null 2>&1 || rc=$?
      if [ "$rc" != "0" ]; then
        echo "not yet: $ingest exited $rc:"
        tail -5 "$log" 2>/dev/null | sed 's/^/    /'
        exit 1
      fi
      if [ ! -s "$log" ]; then
        echo "not yet: $ingest produced no $log for the check to read."
        exit 1
      fi

      line=$(grep -E '^fillrandom' "$log" | head -1 || true)
      if [ -z "$line" ]; then
        echo "not yet: $log has no fillrandom result. The job is 1.2 million records under"
        echo "random keys; a different workload is a different problem."
        exit 1
      fi
      ops=$(printf '%s' "$line"  | grep -oE '[0-9]+ operations' | grep -oE '[0-9]+' || true)
      secs=$(printf '%s' "$line" | grep -oE '[0-9.]+ seconds'   | grep -oE '[0-9.]+' || true)
      rate=$(printf '%s' "$line" | grep -oE '[0-9]+ ops/sec'    | grep -oE '[0-9]+' || true)
      stall=$(grep -oE '^rocksdb\.stall\.micros COUNT : [0-9]+' "$log" | grep -oE '[0-9]+$' || true)
      p999=$(grep -E '^Percentiles' "$log" | head -1 | sed -nE 's/.*P99\.9: ([0-9.]+).*/\1/p' || true)

      reasons() {
        grep -ohE 'Stalling writes because we have [0-9]+ (level-0 files|immutable memtables)' \
          "$db/LOG" 2>/dev/null | sed -E 's/[0-9]+ //' | sort | uniq -c | sed 's/^/    /' || true
      }

      # --- it has to be the same job ------------------------------------------
      if [ "${ops:-0}" != "1200000" ]; then
        echo "not yet: the ingest reports ${ops:-no} records written, and the job is 1200000."
        echo "The pauses go away if you write less; so does the service."
        exit 1
      fi
      if [ ! -d "$db" ]; then
        echo "not yet: there is no store at $db. The check reads the store's own files and"
        echo "its LOG from there, so that is where the ingest has to leave it."
        exit 1
      fi
      size=$(du -sm "$db" 2>/dev/null | cut -f1 || echo 0)
      if [ "${size:-0}" -lt 600 ]; then
        echo "not yet: $db holds ${size} MB and 1.2 million 800-byte records is about 700."
        echo "Dropping or shrinking the data is not what the service needs."
        exit 1
      fi
      if [ -z "$stall" ] || [ -z "$secs" ]; then
        echo "not yet: $log has no statistics block — no 'rocksdb.stall.micros' line. The"
        echo "check reads the store's own counters, so --statistics has to stay on."
        exit 1
      fi

      # --- the writes must stop stopping --------------------------------------
      pct=$(awk -v s="$stall" -v t="$secs" 'BEGIN { printf "%d", (s / 1000000.0) / t * 100 }')
      if [ "${pct:-100}" -ge 10 ]; then
        echo "not yet: the ingest spent ${pct}% of its ${secs} seconds stalled"
        echo "($(( stall / 1000 )) ms of stall against a ${rate} ops/sec average). The store"
        echo "records why it stopped each time:"
        echo
        reasons
        echo
        echo "Each line names the condition the write path was blocked on and the number it"
        echo "had reached. Find which option that number is measured against, and what has"
        echo "to happen for it to come down again."
        exit 1
      fi
      if [ -z "$p999" ]; then
        echo "not yet: $log has no 'Percentiles' line — the check reads the write-latency"
        echo "distribution from it, so --histogram has to stay on."
        exit 1
      fi
      if awk -v p="$p999" 'BEGIN { exit !(p > 500) }'; then
        echo "not yet: the slowest 0.1% of writes took ${p999} microseconds, and the budget is"
        echo "500. The average is fine and always was — the tail is the whole complaint."
        echo
        reasons
        exit 1
      fi

      # --- the backlog has to have drained, not just stopped being refused ----
      summary=$(grep -aoE 'Level summary: files\[[0-9 ]+\][^,]*, estimated pending compaction bytes [0-9]+' \
                  "$db/LOG" 2>/dev/null | tail -1 || true)
      l0=$(printf '%s' "$summary" | sed -nE 's/.*files\[([0-9]+) .*/\1/p' || true)
      if [ -z "$l0" ]; then
        echo "not yet: $db/LOG has no level summary for the check to read. The store writes"
        echo "one on every flush and compaction, so an ingest that produced none did not run"
        echo "against a real store."
        exit 1
      fi
      if [ "$l0" -gt 24 ]; then
        echo "not yet: the writes stopped stalling and the pile did not go away — the store's"
        echo "last level summary reads:"
        echo
        echo "    $summary"
        echo
        echo "${l0} files at level 0, and level-0 files overlap, so every one of them is a file"
        echo "each read has to open. The pause was the store keeping that number down. Raising"
        echo "the number it pauses at removes the pause and leaves the pile, which is the one"
        echo "fix that looks like it worked. The count has to come down while the ingest runs."
        exit 1
      fi

      # --- and the reasons ----------------------------------------------------
      waited=$(field what-the-write-waited-on | tr 'A-Z' 'a-z')
      if ! printf '%s' "$waited" | grep -Eq '\b(compaction|compacting|compactions|flush|flushes|flushing|level-?0|l0|backlog|behind)\b'; then
        echo "not yet: 'what-the-write-waited-on:' does not name what the write path was"
        echo "blocked on. The store writes a line for every pause explaining it:"
        echo
        reasons
        echo
        echo "    grep 'Stalling writes' $db/LOG | head -3"
        exit 1
      fi
      counter=$(field the-counter | tr 'A-Z' 'a-z' | tr -d ' ')
      if ! printf '%s' "$counter" | grep -Eq '(stall|level-?0|l0)'; then
        echo "not yet: 'the-counter:' is not a counter the store publishes. Two places have"
        echo "one: the statistics block at the end of $log, and the reason on each"
        echo "'Stalling writes' line in $db/LOG."
        echo
        echo "    grep -iE 'stall' $log | head -5"
        exit 1
      fi
      disk=$(field why-not-a-faster-disk | tr 'A-Z' 'a-z')
      if ! printf '%s' "$disk" | grep -Eq '\b(trigger|triggers|threshold|thresholds|back-?pressure|backpressure|itself|deliberate|deliberately|on purpose|refus|refuses|refusing|throttl|not the disk|idle|config|configuration|option|options|count|limit)\b'; then
        echo "not yet: 'why-not-a-faster-disk:' does not say what is actually imposing the"
        echo "pause. The device was idle while the writes were stopped, so nothing was"
        echo "waiting on it. Something else decided to stop them, and it decided on a"
        echo "number it was given. Say what."
        exit 1
      fi
      cost=$(field what-the-fix-cost | tr 'A-Z' 'a-z')
      if ! printf '%s' "$cost" | grep -Eq '\b(memory|ram|memtable|memtables|cpu|core|cores|thread|threads|read amplification|read-amplification|amplification|space|recovery|restart|reads)\b'; then
        echo "not yet: 'what-the-fix-cost:' does not name a resource. Every knob here moves"
        echo "work somewhere else — into memory, onto the CPU, onto the read path, or into"
        echo "how long a restart takes. Name the one your fix spent."
        exit 1
      fi

      echo "PASS — 1200000 records in ${secs}s at ${rate} ops/sec, ${pct}% of it stalled,"
      echo "the slowest 0.1% of writes at ${p999} microseconds, and ${l0} files left at level 0."
