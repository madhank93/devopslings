---
kind: lesson
title: "One worker is eating the box — find which"
description: |
  The box is sluggish and load average is climbing. Four processes are running
  and one of them is the problem. Work Brendan Gregg's 60-second checklist to
  identify it by evidence, and stop only that one — the fleet is serving
  traffic.
name: runaway-process
slug: runaway-process
createdAt: "2026-07-31"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 90
    run: |
      install -d /var/lib/queue

      # Three queue workers. Two poll politely. The third has a bug that most
      # people write at least once: a "wait for work" loop with no sleep in it.
      cat > /usr/local/bin/queue-worker <<'PY'
      #!/usr/bin/env python3
      import sys, time

      worker = sys.argv[1]

      # Worker 3 shipped with the sleep removed during a "make it more
      # responsive" change. It is now a spin loop.
      spin = (worker == "3")

      processed = 0
      while True:
          if spin:
              # Busy-wait: burns a whole core doing nothing.
              deadline = time.monotonic() + 0.5
              while time.monotonic() < deadline:
                  processed += 1
          else:
              time.sleep(0.5)
              processed += 1
      PY
      chmod +x /usr/local/bin/queue-worker

      # A memory-hungry but idle process. It looks alarming in top's RES column
      # and is completely innocent — the point being that the biggest number on
      # screen is not automatically the cause.
      cat > /usr/local/bin/cache-warmer <<'PY'
      #!/usr/bin/env python3
      import time
      # ~200 MB resident, allocated once, then idle forever.
      blob = bytearray(200 * 1024 * 1024)
      for i in range(0, len(blob), 4096):
          blob[i] = 1
      while True:
          time.sleep(3600)
      PY
      chmod +x /usr/local/bin/cache-warmer

      cat > /etc/systemd/system/queue-worker@.service <<'UNIT'
      [Unit]
      Description=Queue worker %i

      [Service]
      Type=simple
      ExecStart=/usr/local/bin/queue-worker %i
      UNIT

      cat > /etc/systemd/system/cache-warmer.service <<'UNIT'
      [Unit]
      Description=Cache warmer

      [Service]
      Type=simple
      ExecStart=/usr/local/bin/cache-warmer
      UNIT

      systemctl daemon-reload
      for i in 1 2 3; do systemctl start "queue-worker@$i.service"; done
      systemctl start cache-warmer.service

      # Let the spin loop actually register in /proc before handing over.
      sleep 3
      echo "scenario ready — 3 queue workers and a cache warmer are running"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 90
    run: |
      # Sample CPU time per process over 2s. A process that consumed more than
      # ~50% of a core in that window is still burning the box.
      cpu_ticks() {
        awk '{print $14 + $15}' "/proc/$1/stat" 2>/dev/null || echo 0
      }
      hz=$(getconf CLK_TCK)

      pids=$(pgrep -f '/usr/local/bin/(queue-worker|cache-warmer)' || true)
      declare -A before
      for p in $pids; do before[$p]=$(cpu_ticks "$p"); done
      sleep 2
      for p in $pids; do
        after=$(cpu_ticks "$p")
        used=$(( (after - ${before[$p]:-0}) * 100 / (hz * 2) ))
        if [ "$used" -gt 50 ]; then
          cmd=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)
          echo "not yet: pid $p (${cmd:-gone}) is still burning ${used}% of a core"
          exit 1
        fi
      done

      # The innocent processes must still be running. Killing the whole fleet
      # also makes the CPU graph go flat, and it is the wrong answer: two
      # workers and the cache warmer were serving traffic.
      for unit in queue-worker@1.service queue-worker@2.service cache-warmer.service; do
        if ! systemctl is-active --quiet "$unit"; then
          echo "not yet: $unit is stopped — it was not the problem, and it was doing real work"
          exit 1
        fi
      done

      if systemctl is-active --quiet queue-worker@3.service; then
        echo "not yet: queue-worker@3.service is still running"
        exit 1
      fi

      echo "PASS — worker 3 stopped, the other three left alone. You identified it by measurement, not by killing everything."
---
