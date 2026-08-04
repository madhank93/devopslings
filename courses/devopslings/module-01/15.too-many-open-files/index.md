---
kind: lesson
title: "EMFILE, and the ulimit that never reached the service"
description: |
  feed-gateway cannot get through its own startup. Raising the limit in your
  shell changes nothing, because your shell is not in the service's ancestry.
  Raise it where systemd reads it and the gateway starts — and then dies part
  way through the second batch, because the limit was only half of it.
name: too-many-open-files
slug: too-many-open-files
createdAt: "2026-08-03"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      install -d /srv/feed/in /srv/feed/shards /root/answers /var/lib/devopslings
      rm -f /srv/feed/shards/*.log /srv/feed/in/*.job /srv/feed/processed.log 2>/dev/null || true

      # 90 partitions the gateway holds open for its whole life. This is real
      # work, not a leak — and it is already more than the limit allows, which
      # is why the process cannot finish starting.
      for i in $(seq 0 89); do : > /srv/feed/shards/shard-$(printf '%02d' "$i").log; done

      cat > /usr/local/bin/feed-gateway <<'PY'
      #!/usr/bin/env python3
      import os, time, glob

      IN = "/srv/feed/in"
      OUT = "/srv/feed/processed.log"

      # Long-lived by design: one append handle per shard, for the life of the
      # process.
      shards = [open(p, "a") for p in sorted(glob.glob("/srv/feed/shards/*.log"))]
      print(f"feed-gateway: ready, {len(shards)} shards open", flush=True)

      leaked = []
      processed = 0
      while True:
          for path in sorted(glob.glob(os.path.join(IN, "*.job"))):
              try:
                  # Opened per request and never closed.
                  fh = open(path)
                  payload = fh.read().strip()
                  leaked.append(fh)

                  shards[processed % len(shards)].write(payload + "\n")
                  shards[processed % len(shards)].flush()
                  with open(OUT, "a") as out:
                      out.write(payload + "\n")
                  processed += 1
                  os.unlink(path)
              except OSError as e:
                  print(f"feed-gateway: {e}", flush=True)
                  time.sleep(0.2)
          time.sleep(0.05)
      PY
      chmod 0755 /usr/local/bin/feed-gateway

      cat > /etc/systemd/system/feed-gateway.service <<'UNIT'
      [Unit]
      Description=Feed gateway
      # The start limiter is a different lesson. Without this, a crash loop trips
      # it and the box starts reporting "Start request repeated too quickly",
      # which is a true statement about the wrong problem.
      StartLimitIntervalSec=0

      [Service]
      ExecStart=/usr/local/bin/feed-gateway
      Restart=always
      RestartSec=2
      LimitNOFILE=64

      [Install]
      WantedBy=multi-user.target
      UNIT

      cat > /usr/local/bin/feed-load <<'SH'
      #!/bin/bash
      # Drops N jobs into the gateway's input directory.
      set -euo pipefail
      n=${1:-150}
      for i in $(seq 1 "$n"); do
        printf 'evt-%s-%04d\n' "$(date +%s)" "$i" > "/srv/feed/in/$(date +%s%N)-$i.job"
      done
      echo "feed-load: queued $n jobs"
      SH
      chmod 0755 /usr/local/bin/feed-load

      systemctl daemon-reload
      systemctl enable feed-gateway.service >/dev/null 2>&1 || true
      systemctl reset-failed feed-gateway.service >/dev/null 2>&1 || true
      systemctl restart feed-gateway.service >/dev/null 2>&1 || true
      sleep 3

      cat > /root/questions.txt <<'Q'
      feed-gateway cannot finish starting:

        OSError: [Errno 24] Too many open files: '/srv/feed/shards/shard-61.log'

        1. Give it a descriptor limit it can actually work under. It holds 90
           shard handles open for its whole life, and that is legitimate.
           Set the limit where systemd reads it — `ulimit -n` in your shell does
           not reach a service systemd started.

        2. Then stop it leaking. The check runs two load batches through ONE
           process and compares its open descriptor count between them. Raising
           the limit alone only changes how many batches it survives.

      Every job queued must end up in /srv/feed/processed.log.
      Q

      echo "scenario ready — feed-gateway is crash-looping on EMFILE during startup"
      journalctl -u feed-gateway.service --no-pager -o cat -n 4 2>&1 | tail -4 || true

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      # 1. The limit, read from where systemd applies it.
      lim=$(systemctl show -p LimitNOFILE --value feed-gateway.service 2>/dev/null || echo 0)
      case "$lim" in
        infinity) lim=1048576 ;;
        ''|*[!0-9]*) lim=0 ;;
      esac
      if [ "$lim" -lt 256 ]; then
        echo "not yet: feed-gateway.service has LimitNOFILE=$lim"
        echo "         90 shard handles plus stdio does not fit. Set LimitNOFILE= in the"
        echo "         unit or a drop-in — a ulimit in your shell never reaches a service"
        echo "         that systemd started, because your shell is not its parent."
        exit 1
      fi

      systemctl reset-failed feed-gateway.service >/dev/null 2>&1 || true
      if ! systemctl is-active --quiet feed-gateway.service; then
        systemctl restart feed-gateway.service >/dev/null 2>&1 || true
        sleep 3
      fi
      if ! systemctl is-active --quiet feed-gateway.service; then
        echo "not yet: feed-gateway.service is not running"
        journalctl -u feed-gateway.service --no-pager -o cat -n 5 2>&1 | sed 's/^/         /'
        exit 1
      fi

      count_fds() { ls /proc/"$1"/fd 2>/dev/null | wc -l; }
      queued() { find /srv/feed/in -name '*.job' 2>/dev/null | wc -l; }
      drain() {
        for _ in $(seq 1 120); do
          [ "$(queued)" -eq 0 ] && return 0
          sleep 0.5
        done
        return 1
      }

      pid=$(systemctl show -p MainPID --value feed-gateway.service)
      before_lines=$(wc -l < /srv/feed/processed.log 2>/dev/null || echo 0)

      /usr/local/bin/feed-load 150 >/dev/null
      if ! drain; then
        echo "not yet: the first batch did not drain — $(queued) jobs still queued"
        journalctl -u feed-gateway.service --no-pager -o cat -n 5 2>&1 | sed 's/^/         /'
        exit 1
      fi
      sleep 1
      fds1=$(count_fds "$pid")

      /usr/local/bin/feed-load 150 >/dev/null
      if ! drain; then
        echo "not yet: the second batch did not drain — $(queued) jobs still queued"
        journalctl -u feed-gateway.service --no-pager -o cat -n 5 2>&1 | sed 's/^/         /'
        exit 1
      fi
      sleep 1
      pid2=$(systemctl show -p MainPID --value feed-gateway.service)
      fds2=$(count_fds "$pid2")

      if [ "$pid2" != "$pid" ]; then
        echo "not yet: feed-gateway restarted between the batches (PID $pid -> $pid2)"
        echo "         Restart=always hides a leak by handing the work to a fresh process"
        echo "         with a fresh descriptor table. One process has to survive both."
        exit 1
      fi

      after_lines=$(wc -l < /srv/feed/processed.log 2>/dev/null || echo 0)
      got=$(( after_lines - before_lines ))
      if [ "$got" -lt 300 ]; then
        echo "not yet: 300 jobs were queued and $got were processed"
        exit 1
      fi

      growth=$(( fds2 - fds1 ))
      if [ "$growth" -gt 5 ]; then
        echo "not yet: open descriptors went $fds1 -> $fds2 across the second batch"
        echo "         (+$growth for 150 jobs). The ceiling is higher, so it takes longer"
        echo "         to reach — it still arrives. Each request must give its descriptor"
        echo "         back."
        exit 1
      fi

      echo "PASS — LimitNOFILE=$lim, 300 jobs through one process, descriptors flat at $fds2."
---
