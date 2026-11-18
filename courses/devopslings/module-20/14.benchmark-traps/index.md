---
kind: lesson
title: "The same code, three different numbers"
description: |
  Three people benchmarked the catalog's price lookup this week and reported
  1.4 million calls a second, 30,000, and "somewhere between". Nobody changed
  the code. Write the benchmark that gets the number production will see,
  and gets it again every time it runs.
name: benchmark-traps
slug: benchmark-traps
createdAt: "2026-11-16"
timingSensitive: true

sandbox:
  stack: chaos-stack
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 120
    run: |
      set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-20/*.benchmark-traps
      lesson=$1
      mkdir -p answers
      cp "$lesson/files/bench.py" answers/bench.py
      bash "$lesson/files/neighbour.sh" restart

      echo "scenario ready — the benchmark is answers/bench.py (in sandboxes/chaos-stack)."
      echo "The code it measures, not yours to change: $lesson/files/catalog.py"
      echo "Production's key sample: $lesson/files/workload.py"
      echo
      echo "Run it the way CI does (5 fresh runs, pinned to core 1):"
      echo "  bash $lesson/files/run.sh answers/bench.py"

  verify_done:
    timeout_seconds: 300
    run: |
      set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-20/*.benchmark-traps
      lesson=$1
      if [ ! -s answers/bench.py ]; then
        echo "not yet: answers/bench.py is missing. Rerun the init to get the original back."
        exit 1
      fi
      trap 'bash "$lesson/files/neighbour.sh" cont' EXIT
      bash "$lesson/files/neighbour.sh" start
      num() { tr -dc '0-9.\n' | grep -E '^[0-9]+(\.[0-9]+)?$' | awk '{ printf "%d\n", $1 }' || true; }
      pct() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%d", 100 * a / b }'; }

      # What a benchmark should report: the code warm, on the production keys,
      # the fastest of several passes. Measured under the same neighbour.
      ref=$(bash "$lesson/files/run.sh" "$lesson/solution/bench.py" 3 | num | sort -n | sed -n 2p)
      if [ -z "$ref" ]; then
        echo "not yet: the check's own reference measurement failed. Rerun the init."
        exit 1
      fi

      out=$(bash "$lesson/files/run.sh" answers/bench.py 5)
      runs=$(num <<<"$out")
      if [ "$(grep -c . <<<"$runs" || true)" -lt 5 ]; then
        echo "not yet: answers/bench.py has to print one number, calls a second, as its last line."
        echo "Five runs printed:"
        tail -5 <<<"$out" | sed 's/^/  /'
        exit 1
      fi
      min=$(sort -n <<<"$runs" | head -1); max=$(sort -n <<<"$runs" | tail -1)
      med=$(sort -n <<<"$runs" | sed -n 3p)
      echo "this check ran answers/bench.py five times: $(tr '\n' ' ' <<<"$runs")"
      echo "the code's warm speed on the production keys: $ref calls/s"

      if [ "$(pct "$med" "$ref")" -gt 125 ]; then
        echo "not yet: a median of $med calls a second is far above what production gets ($ref)."
        echo "price() keeps the last 2,048 answers: a benchmark that asks for the same few SKUs is"
        echo "timing the cache, not the code. Ask for what production asks for: workload.KEYS."
        exit 1
      fi

      bash "$lesson/files/neighbour.sh" stop
      quiet=$(bash "$lesson/files/run.sh" answers/bench.py 1 | num | tail -1)
      bash "$lesson/files/neighbour.sh" cont
      if [ "$(pct "${quiet:-0}" "$ref")" -lt 80 ]; then
        echo "not yet: even with the job on core 1 paused, answers/bench.py reported ${quiet:-nothing} calls"
        echo "a second, well below the $ref a running server gets. Each run is a fresh process: the first"
        echo "call builds the rate table and every early lookup misses the cache. A server pays that"
        echo "once, at start. Warm up before you start the clock."
        exit 1
      fi
      if [ "$(pct "$max" "$min")" -gt 115 ] || [ "$(pct "$med" "$ref")" -lt 80 ]; then
        echo "not yet: five runs of the same code gave $min to $max calls a second (median $med, against"
        echo "$ref). With the job on core 1 paused it reported $quiet. That job runs in bursts"
        echo "(files/reindex.py), and time measured during a burst counts the job's work as yours."
        echo "Interference only ever adds time: time several passes separately and keep the fastest."
        exit 1
      fi

      # Doubled cost means slower passes, which a burst can cover whole: the
      # faster of two runs each.
      slowref=$(CATALOG_SLOW=1 bash "$lesson/files/run.sh" "$lesson/solution/bench.py" 2 | num | sort -n | tail -1)
      slow=$(CATALOG_SLOW=1 bash "$lesson/files/run.sh" answers/bench.py 2 | num | sort -n | tail -1)
      if [ -z "$slow" ] || [ -z "$slowref" ] || [ "$(pct "$slow" "$slowref")" -gt 125 ] || [ "$(pct "$slow" "$slowref")" -lt 80 ]; then
        echo "not yet: the check made each price cost twice as much, and answers/bench.py reported ${slow:-nothing}"
        echo "(the reference measured ${slowref:-nothing}). A benchmark has to measure the code it runs."
        exit 1
      fi
      echo "PASS — five runs within $(( $(pct "$max" "$min") - 100 ))% of each other, median $med against the reference $ref,"
      echo "and it noticed when the code got slower ($slow against $slowref)."
---
