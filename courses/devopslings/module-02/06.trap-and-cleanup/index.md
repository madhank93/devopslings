---
kind: lesson
title: "forty temp directories and 38 GB nobody can account for"
description: |
  build-index cleans up after itself on the last line, which runs on exactly one
  of the three ways this script ends. The other two have been quietly filling
  the disk since March.
name: trap-and-cleanup
slug: trap-and-cleanup
createdAt: "2026-08-04"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      install -d /srv/build /srv/scratch /var/lib/devopslings /root/answers
      rm -rf /srv/scratch/* /srv/build/index.out 2>/dev/null || true

      cat > /usr/local/bin/build-index <<'SH'
      #!/bin/bash
      # Build the search index. Uses a scratch directory for intermediates.
      set -euo pipefail

      work=$(mktemp -d /srv/scratch/build-XXXXXX)

      # Stage 1: expand the corpus into the scratch directory.
      for i in $(seq 1 200); do
        printf 'document %d\n' "$i" > "$work/doc-$i.txt"
      done

      # Stage 2: the part that can fail, and the part someone interrupts.
      if [ -e /srv/build/FAIL ]; then
        echo "build-index: corpus is corrupt" >&2
        exit 5
      fi
      sleep "${BUILD_SECONDS:-0}"

      # Stage 3: emit the index.
      find "$work" -name 'doc-*.txt' | wc -l > /srv/build/index.out

      # The cleanup. Only ever reached when everything above worked.
      rm -rf "$work"
      echo "build-index: done"
      SH
      chmod 0755 /usr/local/bin/build-index

      # Three months of leftovers.
      for i in 1 2 3; do
        d=$(mktemp -d /srv/scratch/build-XXXXXX)
        printf 'orphaned intermediate\n' > "$d/doc-1.txt"
      done

      cat > /root/questions.txt <<'Q'
      /usr/local/bin/build-index makes a scratch directory under /srv/scratch and
      removes it on its last line. /srv/scratch currently has leftovers from
      runs that never reached that line.

      Make it remove its scratch directory on EVERY way out:

        - a normal, successful run
        - a run that fails (touch /srv/build/FAIL to make stage 2 fail)
        - a run that is interrupted (SIGINT or SIGTERM part way through)

      A successful run must still write /srv/build/index.out containing 200.
      Clean up the existing leftovers too.
      Q

      echo "scenario ready — $(find /srv/scratch -maxdepth 1 -type d -name 'build-*' | wc -l) orphaned scratch directories"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      bin=/usr/local/bin/build-index
      if [ ! -x "$bin" ]; then
        echo "not yet: $bin is missing or not executable"
        exit 1
      fi

      count_scratch() { find /srv/scratch -maxdepth 1 -type d -name 'build-*' 2>/dev/null | wc -l; }

      # The old leftovers must be gone.
      if [ "$(count_scratch)" -ne 0 ]; then
        echo "not yet: $(count_scratch) orphaned scratch directories are still in /srv/scratch"
        echo "         fixing the script does not remove what earlier runs already left."
        exit 1
      fi

      # 1. Normal exit.
      rm -f /srv/build/FAIL /srv/build/index.out
      set +e
      "$bin" >/tmp/b.log 2>&1; rc=$?
      set -e
      if [ "$rc" -ne 0 ]; then
        echo "not yet: a normal run exited $rc"
        sed 's/^/         /' /tmp/b.log | tail -5
        exit 1
      fi
      if [ "$(cat /srv/build/index.out 2>/dev/null)" != "200" ]; then
        echo "not yet: a successful run must leave /srv/build/index.out containing 200"
        echo "         it contains: '$(cat /srv/build/index.out 2>/dev/null)'"
        exit 1
      fi
      if [ "$(count_scratch)" -ne 0 ]; then
        echo "not yet: a successful run left $(count_scratch) scratch directory behind"
        exit 1
      fi

      # 2. Error exit.
      touch /srv/build/FAIL
      set +e
      "$bin" >/tmp/b.log 2>&1; rc=$?
      set -e
      rm -f /srv/build/FAIL
      if [ "$rc" -eq 0 ]; then
        echo "not yet: the run with a corrupt corpus exited 0 — it must still fail"
        exit 1
      fi
      if [ "$(count_scratch)" -ne 0 ]; then
        echo "not yet: the failing run left $(count_scratch) scratch directory behind"
        echo "         the cleanup on the last line is not reached when the script exits"
        echo "         early. It has to run on the way out, however the way out happens."
        exit 1
      fi

      # 3. Interrupted, twice — once with SIGINT and once with SIGTERM.
      for sig in INT TERM; do
        rm -f /srv/build/FAIL
        BUILD_SECONDS=30 "$bin" >/tmp/b.log 2>&1 &
        pid=$!
        # Wait for the scratch directory to actually exist before interrupting.
        for _ in $(seq 1 40); do
          [ "$(count_scratch)" -gt 0 ] && break
          sleep 0.25
        done
        if [ "$(count_scratch)" -eq 0 ]; then
          kill -9 "$pid" 2>/dev/null || true
          echo "not yet: could not observe a scratch directory being created"
          exit 1
        fi
        kill -"$sig" "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        sleep 1
        if [ "$(count_scratch)" -ne 0 ]; then
          echo "not yet: a run interrupted with SIG$sig left $(count_scratch) scratch"
          echo "         directory behind. This is the path that produced the 38 GB —"
          echo "         somebody pressed Ctrl-C, or a deploy sent SIGTERM."
          find /srv/scratch -maxdepth 1 -type d -name 'build-*' -printf '           %f\n' | head -3
          rm -rf /srv/scratch/build-* 2>/dev/null || true
          exit 1
        fi
      done

      echo "PASS — scratch cleaned up on success, on failure, and on both SIGINT and"
      echo "       SIGTERM; a successful run still writes index.out = 200."
---
