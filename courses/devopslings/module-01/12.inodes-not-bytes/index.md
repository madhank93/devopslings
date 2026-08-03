---
kind: lesson
title: "no space left on device, and 64M free"
description: |
  checkout-api cannot write. ENOSPC on every attempt. `df -h` says the
  filesystem is 0% full and there is no big file to find, because bytes were
  never the resource that ran out. There is a cleanup job, it runs nightly, and
  it was written to reclaim the wrong thing.
name: inodes-not-bytes
slug: inodes-not-bytes
createdAt: "2026-08-03"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      install -d /var/lib/devopslings /root/answers

      # A small filesystem with a small inode table. Bytes are plentiful and
      # inodes are not, which is the whole scenario and is otherwise awkward to
      # arrange on a box this size.
      umount /srv/spool 2>/dev/null || true
      rm -rf /srv/spool
      mkdir -p /srv/spool
      mount -t tmpfs -o size=64m,nr_inodes=2000 tmpfs /srv/spool

      mkdir -p /srv/spool/sessions /srv/spool/payload

      # The payload is the thing that must survive. `rm -rf /srv/spool/*` frees
      # every inode and fails the check.
      for i in $(seq 1 12); do
        printf 'order-batch %02d\npayload for settlement run 2026-08-03\n' "$i" \
          > /srv/spool/payload/batch-$i.dat
      done
      sha256sum /srv/spool/payload/* | sha256sum | awk '{print $1}' \
        > /var/lib/devopslings/inodes.payload.sha256

      # Three days of session files that nothing ever removed. Each is a few
      # bytes; together they are almost the entire inode table.
      i=0
      while : > /srv/spool/sessions/sess-$(printf '%05d' $i) 2>/dev/null; do
        printf 'uid=%d\n' $((i % 500)) > /srv/spool/sessions/sess-$(printf '%05d' $i) 2>/dev/null || break
        i=$((i + 1))
        [ "$i" -gt 2500 ] && break
      done
      find /srv/spool/sessions -type f -exec touch -d '3 days ago' {} +

      # The cleanup that runs every night and has never reclaimed anything.
      # It was written during a disk-full incident two years ago, when the
      # problem genuinely was large files.
      cat > /usr/local/bin/session-reaper <<'SH'
      #!/bin/bash
      set -euo pipefail
      find /srv/spool/sessions -type f -size +1M -delete
      echo "session-reaper: done"
      SH
      chmod 0755 /usr/local/bin/session-reaper

      cat > /etc/systemd/system/session-reaper.service <<'UNIT'
      [Unit]
      Description=Prune stale checkout sessions

      [Service]
      Type=oneshot
      ExecStart=/usr/local/bin/session-reaper
      UNIT
      systemctl daemon-reload

      cat > /root/questions.txt <<'Q'
      checkout-api cannot write to /srv/spool. Get it writing again, and make
      sure tonight's run does not put you back here.

        - /srv/spool/payload/ must survive intact. It is the settlement batch.
        - session-reaper.service runs nightly and must actually reclaim what is
          being consumed. The check seeds fresh stale sessions and runs it.
        - Session files younger than a day are live. Do not delete those.
      Q

      echo "scenario ready — writes to /srv/spool are failing"
      df -h /srv/spool | tail -1
      df -i /srv/spool | tail -1

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      if ! mountpoint -q /srv/spool; then
        echo "not yet: /srv/spool is not mounted any more — reset the lesson"
        exit 1
      fi

      want_payload=$(cat /var/lib/devopslings/inodes.payload.sha256)
      got_payload=$(sha256sum /srv/spool/payload/* 2>/dev/null | sha256sum | awk '{print $1}')
      if [ "$got_payload" != "$want_payload" ]; then
        n=$(find /srv/spool/payload -type f 2>/dev/null | wc -l)
        echo "not yet: /srv/spool/payload is not intact — $n of 12 files present"
        echo "         deleting everything under /srv/spool frees the inodes and destroys"
        echo "         the settlement batch. The stale sessions were the problem, not the"
        echo "         payload."
        exit 1
      fi

      used_pct=$(df -i /srv/spool | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
      if [ "${used_pct:-100}" -ge 50 ]; then
        echo "not yet: inode usage on /srv/spool is ${used_pct}%"
        df -i /srv/spool | sed 's/^/         /'
        exit 1
      fi

      # Writes work again.
      if ! : > /srv/spool/.probe 2>/dev/null; then
        echo "not yet: still cannot create a file on /srv/spool"
        exit 1
      fi
      rm -f /srv/spool/.probe

      # The recurrence. Seed what tonight looks like: stale sessions that must
      # go, and live ones that must not.
      mkdir -p /srv/spool/sessions
      for i in $(seq 1 400); do printf 'uid=%d\n' "$i" > /srv/spool/sessions/probe-old-$i; done
      find /srv/spool/sessions -name 'probe-old-*' -exec touch -d '3 days ago' {} +
      for i in $(seq 1 40); do printf 'uid=%d\n' "$i" > /srv/spool/sessions/probe-new-$i; done

      systemctl reset-failed session-reaper.service >/dev/null 2>&1 || true
      if ! systemctl start session-reaper.service >/dev/null 2>&1; then
        echo "not yet: session-reaper.service failed to run"
        systemctl --no-pager --lines=5 status session-reaper.service 2>&1 | tail -6
        rm -f /srv/spool/sessions/probe-old-* /srv/spool/sessions/probe-new-*
        exit 1
      fi

      left_old=$(find /srv/spool/sessions -name 'probe-old-*' 2>/dev/null | wc -l)
      left_new=$(find /srv/spool/sessions -name 'probe-new-*' 2>/dev/null | wc -l)
      rm -f /srv/spool/sessions/probe-old-* /srv/spool/sessions/probe-new-* 2>/dev/null || true

      if [ "$left_old" -gt 0 ]; then
        echo "not yet: session-reaper left $left_old of 400 stale session files behind"
        echo "         it still is not reclaiming what actually runs out. Look at what it"
        echo "         matches on — these files are a few bytes each, and always will be."
        exit 1
      fi
      if [ "$left_new" -lt 40 ]; then
        echo "not yet: session-reaper deleted $((40 - left_new)) of 40 live sessions"
        echo "         those are today's — pruning everything logs users out. Prune by age."
        exit 1
      fi

      echo "PASS — inodes at ${used_pct}%, payload intact, and the reaper now prunes stale"
      echo "       sessions while leaving live ones alone."
---
