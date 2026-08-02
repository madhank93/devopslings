---
kind: lesson
title: "The disk is full but du says it isn't"
description: |
  /var/log/app is at 91% and climbing, but `du` can only account for a few
  kilobytes of it. Deleting files does nothing. Learn to find space that is
  held by a process rather than by a directory entry — and why killing the
  process is not the same as fixing it.
name: disk-full-triage
slug: disk-full-triage
createdAt: "2026-07-31"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 60
    run: |
      install -d /var/log/app

      # The culprit: a "cleanup" that unlinks its scratch file but keeps the
      # handle open. The space stays allocated until the fd closes, and no
      # directory entry points at it — so du cannot see it and rm cannot free
      # it. This is one of the most common real disk-full causes there is.
      cat > /usr/local/bin/log-exporter <<'PY'
      #!/usr/bin/env python3
      import os, time

      SCRATCH = "/var/log/app/export.tmp"

      with open(SCRATCH, "wb") as f:
          chunk = b"x" * (1024 * 1024)
          for _ in range(58):
              f.write(chunk)
          f.flush()
          os.fsync(f.fileno())

          # "Tidy up after ourselves."
          os.unlink(SCRATCH)

          # ...and then stay resident until the next scheduled run.
          while True:
              time.sleep(3600)
      PY
      chmod +x /usr/local/bin/log-exporter

      cat > /etc/systemd/system/log-exporter.service <<'UNIT'
      [Unit]
      Description=Nightly report exporter
      After=local-fs.target

      [Service]
      Type=simple
      ExecStart=/usr/local/bin/log-exporter
      Restart=always
      RestartSec=2

      [Install]
      WantedBy=multi-user.target
      UNIT

      # A couple of real, small log files, so the directory is not suspiciously
      # empty when the student finally runs du.
      printf 'ready\n' > /var/log/app/app.log
      printf 'ok\n'    > /var/log/app/access.log

      systemctl daemon-reload
      systemctl enable --now log-exporter.service >/dev/null 2>&1

      # Wait for the space to actually be consumed, so the student never sees a
      # healthy df on first look.
      for _ in $(seq 30); do
        used=$(df --output=pcent /var/log/app | tail -1 | tr -dc '0-9')
        [ "${used:-0}" -ge 80 ] && break
        sleep 1
      done
      echo "scenario ready — /var/log/app is at ${used:-?}%"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 60
    run: |
      # 1. The space is actually back.
      avail=$(df --output=avail -BM /var/log/app | tail -1 | tr -dc '0-9')
      if [ "${avail:-0}" -lt 50 ]; then
        echo "not yet: /var/log/app has only ${avail:-0}M free — the space is still held"
        exit 1
      fi

      # 2. Nothing is still holding a deleted file on that mount. This is the
      #    check that distinguishes understanding from luck: a student who
      #    deleted random files would not clear it.
      if lsof -nP +L1 2>/dev/null | grep -q '/var/log/app'; then
        echo "not yet: a process still holds a deleted file open under /var/log/app"
        exit 1
      fi

      # 3. The service is stopped, not merely killed. `kill` gives the space
      #    back for two seconds and then Restart=always takes it again — if the
      #    student only killed the PID, they were about to be paged a second
      #    time.
      if systemctl is-active --quiet log-exporter.service; then
        echo "not yet: log-exporter.service is running again — did you kill the process instead of stopping the unit?"
        exit 1
      fi

      # 4. The real log files are intact. Deleting them frees nothing and loses
      #    evidence, which is the wrong instinct to reward.
      for f in app.log access.log; do
        if [ ! -f "/var/log/app/$f" ]; then
          echo "not yet: /var/log/app/$f is gone — those were real logs, and they were not the problem"
          exit 1
        fi
      done

      echo "PASS — ${avail}M free. You found space that had no directory entry, and you stopped the unit rather than the process."
---
